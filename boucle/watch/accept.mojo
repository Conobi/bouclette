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

    Implements _FutureCallback so the generic _dispatch can deliver
    completion results into this struct and the WatchLoop registry can settle
    its ownership. Stored on the heap; the Completion's context pointer
    points back to the enclosing _AcceptFutureState.

    Fields:
        completion: The per-operation completion token (fn ptr + context
                    ptr) whose address the driver holds.
        _socket_fd: The accepted socket fd (-1 = not yet set).
        _error_code: The errno on failure (0 = no error).
        done: True once the completion callback has fired.
        consumed: True once result() has been called.
        _owner_dropped: True if the AcceptFuture was dropped before done;
                        the WatchLoop then frees this state.
        _loop_gone: True if the WatchLoop was destroyed before done;
                    the AcceptFuture then frees this state.
        _link: The slot this state lives in and the loop's settle queue.
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
        """Construct an _AcceptFutureState.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context once the state is in its slot.
        """
        self.completion = Completion()
        self._socket_fd = Int32(-1)
        self._error_code = Int32(0)
        self.done = False
        self.consumed = False
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source state to move from.
        """
        self.completion = move.completion^
        self._socket_fd = move._socket_fd
        self._error_code = move._error_code
        self.done = move.done
        self.consumed = move.consumed
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def set_result(mut self, result: Int):
        """Store the completion result from accept operation and mark done.

        On success (result >= 0), stores the accepted fd.
        On failure (result < 0), stores the negated errno.

        Args:
            result: The completion result reported by the backend
                    (accepted fd, or negative errno on failure).
        """
        if result >= 0:
            self._socket_fd = Int32(result)
        else:
            self._error_code = Int32(-result)
        self.done = True

    def is_done(self) -> Bool:
        """Return True once the completion callback has fired.

        Returns:
            True if no callback will write this state again.
        """
        return self.done

    def owner_dropped(self) -> Bool:
        """Return True if the AcceptFuture was dropped before completion.

        Returns:
            True if the WatchLoop must free this state.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        Returns:
            True if the AcceptFuture is the sole remaining owner.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this accept in flight.
        """
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Record the slot this state lives in and the queue to notify.

        Args:
            link: The slot key and the loop's settle queue.
        """
        self._link = link

    def notify_done(self):
        """Tell the slot link the completion has arrived."""
        self._link.completed(self._owner_dropped)

    def mark_owner_dropped(mut self):
        """Record that the handle let go, and queue the slot if done."""
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
        """Construct an AcceptFuture wrapping a slab-owned state.

        Args:
            state: Pointer to the slab-owned _AcceptFutureState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source AcceptFuture to move from.
        """
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

        Returns:
            The accepted Socket wrapping an OwnedHandle.

        Raises:
            IOError if the accept syscall failed. A plain message if the
            result was already consumed, the loop was destroyed before
            the operation completed, or the operation has not completed.
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
        """Return True if the accept operation has completed.

        Stays False forever if the loop was destroyed first; result()
        then raises with the reason.

        Returns:
            True once the completion callback has fired (success or failure).
        """
        return self._state[].done
