"""ConnectFuture — async connect via WatchLoop.

_ConnectFutureState holds the per-operation Completion token, a copy of
the target address storage (for pointer stability), and the raw
completion result. ConnectFuture is the RAII handle returned to callers — it owns
the heap-allocated state and decodes the result into a ConnectOutcome.

The state is shared with the WatchLoop that submitted the connect (see
`_callback.mojo` for the ownership rules). Dropping the ConnectFuture
before the completion arrives is safe: the loop frees the state once it
is done or when the loop itself is destroyed. Destroying the loop before
the completion arrives is also safe: the future frees the state on drop
and result() reports the destroyed loop.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.net.addr import SocketAddrStorV4
from boucle.proactor.completion import Completion
from boucle.watch._callback import _FutureCallback, _dispatch
from boucle.watch.outcome import ConnectOutcome


# ===----------------------------------------------------------------------=== #
# _ConnectFutureState — internal, heap-allocated per-operation state
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

    Fields:
        completion: The per-operation completion token (fn ptr + context
                    ptr) whose address the driver holds.
        _addr_stor: Copy of the target address for pointer stability.
        _result: Raw completion result (0 on success, negative errno on
                 failure).
        done: True once the completion callback has fired.
        consumed: True once result() has been called.
        _owner_dropped: True if the ConnectFuture was dropped before done;
                        the WatchLoop then frees this state.
        _loop_gone: True if the WatchLoop was destroyed before done;
                    the ConnectFuture then frees this state.
    """

    var completion: Completion
    var _addr_stor: SocketAddrStorV4
    var _result: Int
    var done: Bool
    var consumed: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool

    def __init__(out self, addr_stor: SocketAddrStorV4):
        """Construct a _ConnectFutureState with address storage.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context after heap allocation.

        Args:
            addr_stor: Copy of the target sockaddr_in for pointer stability.
        """
        self.completion = Completion()
        self._addr_stor = addr_stor
        self._result = 0
        self.done = False
        self.consumed = False
        self._owner_dropped = False
        self._loop_gone = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source state to move from.
        """
        self.completion = move.completion^
        self._addr_stor = move._addr_stor
        self._result = move._result
        self.done = move.done
        self.consumed = move.consumed
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone

    def set_result(mut self, result: Int):
        """Store the raw completion result of the connect and mark it done.

        Does not decode the result — ConnectFuture.result() handles that
        via ConnectOutcome.from_result().

        Args:
            result: The completion result reported by the backend (0 on
                    success, negative errno on failure).
        """
        self._result = result
        self.done = True

    def is_done(self) -> Bool:
        """Return True once the completion callback has fired.

        Returns:
            True if no callback will write this state again.
        """
        return self.done

    def owner_dropped(self) -> Bool:
        """Return True if the ConnectFuture was dropped before completion.

        Returns:
            True if the WatchLoop must free this state.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        Returns:
            True if the ConnectFuture is the sole remaining owner.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this connect in flight."""
        self._loop_gone = True


# ===----------------------------------------------------------------------=== #
# ConnectFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct ConnectFuture(Movable):
    """RAII handle for an in-flight async connect operation.

    Owns a heap-allocated _ConnectFutureState. Call done() to check
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
        """Construct a ConnectFuture wrapping a heap-allocated state.

        Args:
            state: Pointer to the heap-allocated _ConnectFutureState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source ConnectFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the completion has been delivered, or the loop has already
        been destroyed, this handle is the last owner and frees the
        state. Otherwise the loop still tracks the state (and the
        operation may still point at the copied address storage), so it
        is marked as orphaned and the loop frees it — after the
        completion arrives during run(), or when the loop itself is
        destroyed.

        No fd cleanup needed — connect does not produce a new fd.
        """
        if self._state[].done or self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
            self._state.unsafe_free()
        else:
            self._state[]._owner_dropped = True

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
