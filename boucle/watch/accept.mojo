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

from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.socle.linux.fd import close_unchecked
from boucle.watch._callback import _FutureCallback, _dispatch


# ===----------------------------------------------------------------------=== #
# _AcceptFutureState — internal, heap-allocated per-operation state
# ===----------------------------------------------------------------------=== #


struct _AcceptFutureState(_FutureCallback):
    """Internal state for a single async accept operation.

    Implements _FutureCallback so the generic _dispatch can deliver
    completion results into this struct and the WatchLoop registry can settle
    its ownership. Stored on the heap; the Completion's context pointer
    points back to the enclosing _AcceptFutureState.

    Fields:
        completion: The io_uring completion token (fn ptr + context ptr).
        _socket_fd: The accepted socket fd (-1 = not yet set).
        _error_code: The errno on failure (0 = no error).
        done: True once the completion callback has fired.
        consumed: True once result() has been called.
        _owner_dropped: True if the AcceptFuture was dropped before done;
                        the WatchLoop then frees this state.
        _loop_gone: True if the WatchLoop was destroyed before done;
                    the AcceptFuture then frees this state.
    """

    var completion: Completion
    var _socket_fd: Int32
    var _error_code: Int32
    var done: Bool
    var consumed: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool

    def __init__(out self):
        """Construct an _AcceptFutureState.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context after heap allocation.
        """
        self.completion = Completion()
        self._socket_fd = Int32(-1)
        self._error_code = Int32(0)
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
        self._socket_fd = move._socket_fd
        self._error_code = move._error_code
        self.done = move.done
        self.consumed = move.consumed
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone

    def set_result(mut self, result: Int):
        """Store the completion result from accept operation and mark done.

        On success (result >= 0), stores the accepted fd.
        On failure (result < 0), stores the negated errno.

        Args:
            result: The io_uring completion result (accepted fd or negative errno).
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
        """Record that the WatchLoop was destroyed with this accept in flight."""
        self._loop_gone = True

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

    Owns a heap-allocated _AcceptFutureState. Call done() to check
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
        """Construct an AcceptFuture wrapping a heap-allocated state.

        Args:
            state: Pointer to the heap-allocated _AcceptFutureState.
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

        If the completion has been delivered, or the loop has already
        been destroyed, this handle is the last owner and frees the
        state. Otherwise the loop still tracks the state, so it is
        marked as orphaned and the loop frees it — after the completion arrives
        during run(), or when the loop itself is destroyed.

        Either way, destroying the state closes the accepted fd if
        result() was never called (see _AcceptFutureState.__deinit__).
        """
        if self._state[].done or self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
            self._state.unsafe_free()
        else:
            self._state[]._owner_dropped = True

    def result(mut self) raises -> Socket:
        """Extract the accepted Socket from a completed accept.

        Consumes the result — a second call raises. The returned Socket
        owns the accepted fd; the AcceptFuture no longer closes it on drop.

        Returns:
            The accepted Socket wrapping an OwnedHandle.

        Raises:
            If the result was already consumed, the loop was destroyed
            before the operation completed, the operation has not
            completed, or the accept syscall returned an error.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            if self._state[]._loop_gone:
                raise "loop destroyed before completion"
            raise "operation not complete"
        self._state[].consumed = True
        if self._state[]._error_code != Int32(0):
            raise String(
                "accept failed: errno ", Int(self._state[]._error_code)
            )
        return Socket(OwnedHandle(raw=self._state[]._socket_fd))

    def done(self) -> Bool:
        """Return True if the accept operation has completed.

        Stays False forever if the loop was destroyed first; result()
        then raises with the reason.

        Returns:
            True once the completion callback has fired (success or failure).
        """
        return self._state[].done
