"""AcceptFuture — async accept via WatchLoop.

_AcceptFutureState holds the per-operation Completion token and the completion
result (accepted fd or errno). AcceptFuture is the RAII handle returned
to callers. Destroying the state closes an unclaimed accepted fd, so the
fd never leaks whichever party frees the state.

The state is shared with the WatchLoop that submitted the accept (see
`_callback.mojo` for the ownership rules). Dropping the AcceptFuture
before the completion arrives is safe: the loop frees the state once it
is done or when the loop itself is destroyed. Destroying the loop before
the completion arrives is also safe: the future frees the state on drop
and result() reports the destroyed loop.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.error import IOError
from boucle.handle import OwnedHandle
from boucle.net.options import SocketType
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.socle.platform import close_unchecked
from boucle.watch._callback import _FutureCallback, _SlotLink, _dispatch


# ===----------------------------------------------------------------------=== #
# _AcceptFutureState — internal, slab-owned per-operation state
# ===----------------------------------------------------------------------=== #


struct _AcceptFutureState(_FutureCallback):
    """Internal state for a single async accept operation.

    Implements `_FutureCallback` so the generic `_dispatch` can deliver
    completion results and the slab can settle ownership. The Completion's
    context pointer points back to the enclosing state.
    """

    var completion: Completion
    var _socket_fd: Int32
    var _error_code: Int32
    var done: Bool
    var consumed: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(out self):
        """No-op completion; caller wires invoke and context after slab placement."""
        self.completion = Completion()
        self._socket_fd = Int32(-1)
        self._error_code = Int32(0)
        self.done = False
        self.consumed = False
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        self.completion = move.completion^
        self._socket_fd = move._socket_fd
        self._error_code = move._error_code
        self.done = move.done
        self.consumed = move.consumed
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def set_result(mut self, result: Int):
        """Store the accepted fd (>= 0) or negated errno (< 0) and mark done."""
        if result >= 0:
            self._socket_fd = Int32(result)
        else:
            self._error_code = Int32(-result)
        self.done = True

    def is_done(self) -> Bool:
        """No further callbacks will write this state."""
        return self.done

    def owner_dropped(self) -> Bool:
        """The `AcceptFuture` handle was dropped; the loop must free this state."""
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """The loop was destroyed; the future handle is the sole owner."""
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the loop was destroyed with this accept in flight."""
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Bind to the slab slot and settle queue."""
        self._link = link

    def notify_done(self):
        """Push the slot onto the settle queue."""
        self._link.completed(self._owner_dropped)

    def mark_owner_dropped(mut self):
        """Record that the handle let go; queue the slot if already done."""
        self._owner_dropped = True
        self._link.dropped(self.done)

    def __deinit__(deinit self):
        """Close the accepted fd if nobody claimed it.

        Runs whichever party destroys the state — the AcceptFuture handle
        or the WatchLoop on the orphaned path — so an accept whose
        result() is never called can never leak its fd.
        """
        if not self.consumed and self._socket_fd >= 0:
            close_unchecked(unsafe_fd=self._socket_fd)


# ===----------------------------------------------------------------------=== #
# AcceptFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct AcceptFuture(Movable):
    """RAII handle for an in-flight async accept operation.

    Points at a slab-owned _AcceptFutureState. Call done() to check
    completion, then result() to extract the accepted Socket.

    If dropped without calling result() and the accept succeeded,
    the accepted fd is closed to prevent resource leaks. Dropping the
    handle before run() has delivered the completion is safe: the loop
    keeps the state alive and closes the fd itself. Destroying the loop
    before completion is also safe (result() then raises).
    """

    var _state: Pointer[_AcceptFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_AcceptFutureState, MutUntrackedOrigin],
    ):
        """Wrap a slab-owned state."""
        self._state = state

    def __init__(out self, *, deinit move: Self):
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the loop has already been destroyed, this handle is the last
        reader of the state and destroys its contents here; the slot
        memory stays with the leaked slab. Otherwise the state is marked
        as orphaned and the loop's slab releases it — at the sweep after
        the completion arrives, or when the loop itself is destroyed.

        Either way, destroying the state closes the accepted fd if
        result() was never called (see _AcceptFutureState.__deinit__).
        """
        if self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
        else:
            self._state[].mark_owner_dropped()

    def result(mut self) raises -> Socket:
        """Extract the accepted Socket from a completed accept.

        Consumes the result — a second call raises. The returned Socket
        owns the accepted fd; the AcceptFuture no longer closes it on drop.

        Two shapes of failure come out of here. A failed accept raises an
        `IOError` carrying the errno, the same type every boucle I/O call
        raises. Misusing the handle raises a plain message instead — no
        syscall failed, so there is no errno to report.

        Raises:
            IOError if the accept syscall failed; a plain message if
            already consumed, not yet complete, or the loop was destroyed.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            if self._state[]._loop_gone:
                raise "loop destroyed before completion"
            raise "operation not complete"
        self._state[].consumed = True
        if self._state[]._error_code != Int32(0):
            raise IOError.from_errno(Int(self._state[]._error_code))
        return Socket(
            OwnedHandle(raw=self._state[]._socket_fd), type=SocketType.STREAM
        )

    def done(self) -> Bool:
        """Stays False forever if the loop was destroyed first."""
        return self._state[].done
