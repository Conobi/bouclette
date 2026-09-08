"""ConnectFuture — async connect via WatchLoop.

_ConnectFutureState holds the per-operation Completion token, a copy of
the target address storage (for pointer stability), and the raw
completion result. ConnectFuture is the RAII handle returned to callers — it points
at the slab-owned state and decodes the result into a ConnectOutcome.

The state is shared with the WatchLoop that submitted the connect (see
`_callback.mojo` for the ownership rules). Dropping the ConnectFuture
before the completion arrives is safe: the loop frees the state once it
is done or when the loop itself is destroyed. Destroying the loop before
the completion arrives is also safe: the future frees the state on drop
and result() reports the destroyed loop.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.net.addr import SocketAddrStorAny
from boucle.proactor.completion import Completion
from boucle.watch._callback import _FutureCallback, _SlotLink, _dispatch
from boucle.watch.outcome import ConnectOutcome


# ===----------------------------------------------------------------------=== #
# _ConnectFutureState — internal, slab-owned per-operation state
# ===----------------------------------------------------------------------=== #


struct _ConnectFutureState(_FutureCallback):
    """Internal state for a single async connect operation.

    Implements _FutureCallback so the generic _dispatch can deliver
    completion results into this struct and the WatchLoop registry can
    settle its ownership. Stored on the heap; the Completion's context
    pointer points back to the enclosing _ConnectFutureState.

    The address storage is copied into this struct so that the pointer
    handed to the driver remains valid until the completion fires,
    regardless of the caller's stack lifetime.
    """

    var completion: Completion
    var _addr_stor: SocketAddrStorAny
    var _result: Int
    var done: Bool
    var consumed: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(out self, addr_stor: SocketAddrStorAny):
        """Construct a _ConnectFutureState with address storage.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context once the state is in its slot.

        Args:
            addr_stor: Copy of the target sockaddr (IPv4 or IPv6) for
                       pointer stability.
        """
        self.completion = Completion()
        self._addr_stor = addr_stor
        self._result = 0
        self.done = False
        self.consumed = False
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        self.completion = move.completion^
        self._addr_stor = move._addr_stor
        self._result = move._result
        self.done = move.done
        self.consumed = move.consumed
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def set_result(mut self, result: Int):
        """Store the raw completion result of the connect and mark it done.

        Does not decode the result — ConnectFuture.result() handles that
        via ConnectOutcome.from_result().
        """
        self._result = result
        self.done = True

    def is_done(self) -> Bool:
        """Return True once the completion callback has fired.
        """
        return self.done

    def owner_dropped(self) -> Bool:
        """Return True if the ConnectFuture was dropped before completion.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this connect in flight.
        """
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Record the slot this state lives in and the queue to notify.
        """
        self._link = link

    def notify_done(self):
        """Tell the slot link the completion has arrived."""
        self._link.completed(self._owner_dropped)

    def mark_owner_dropped(mut self):
        """Record that the handle let go, and queue the slot if done."""
        self._owner_dropped = True
        self._link.dropped(self.done)


# ===----------------------------------------------------------------------=== #
# ConnectFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct ConnectFuture(Movable):
    """RAII handle for an in-flight async connect operation.

    Points at a slab-owned _ConnectFutureState. Call done() to check
    completion, then result() to extract the ConnectOutcome. Dropping
    the future before completion is safe, as is destroying the loop
    before completion (result() then raises).

    Unlike AcceptFuture, no fd cleanup is needed on drop — connect does
    not produce a new fd; it modifies the existing socket in place.
    """

    var _state: Pointer[_ConnectFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_ConnectFutureState, MutUntrackedOrigin],
    ):
        """Construct a ConnectFuture wrapping a slab-owned state.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the loop has already been destroyed, this handle is the last
        reader of the state and destroys its contents here; the slot
        memory stays with the leaked slab. Otherwise the state is marked
        as orphaned (the operation may still point at the copied address
        storage) and the loop's slab releases it — at the sweep after
        the completion arrives, or when the loop itself is destroyed.

        No fd cleanup needed — connect does not produce a new fd.
        """
        if self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
        else:
            self._state[].mark_owner_dropped()

    def result(mut self) raises -> ConnectOutcome:
        """Decode the completion result into a ConnectOutcome.

        Consumes the result — a second call raises. Does NOT raise on
        REFUSED/TIMEOUT — those are valid ConnectOutcome variants.

        Returns:
            A ConnectOutcome discriminating CONNECTED, REFUSED, TIMEOUT,
            NETWORK_UNREACHABLE, or ERROR.

        Raises:
            A plain message if the result was already consumed, the loop
            was destroyed before the operation completed, or the
            operation has not completed. A failed connect is not an
            exception here — it comes back as a ConnectOutcome.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            if self._state[]._loop_gone:
                raise "loop destroyed before completion"
            raise "operation not complete"
        self._state[].consumed = True
        return ConnectOutcome.from_result(self._state[]._result)

    def done(self) -> Bool:
        """Return True if the connect operation has completed.

        Stays False forever if the loop was destroyed first; result()
        then raises with the reason.

        Returns:
            True once the completion callback has fired (success or
            failure).
        """
        return self._state[].done
