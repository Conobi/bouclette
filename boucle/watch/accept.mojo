"""AcceptFuture — async accept via WatchLoop.

_AcceptFutureState holds the per-operation Completion token and the CQE
result (accepted fd or errno). AcceptFuture is the RAII handle returned
to callers — it owns the heap-allocated state and cleans up on drop,
closing unclaimed accepted fds to prevent resource leaks.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.socle.linux.fd import close_unchecked
from boucle.watch._callback import _FutureCallback, _trampoline


# ===----------------------------------------------------------------------=== #
# _AcceptFutureState — internal, heap-allocated per-operation state
# ===----------------------------------------------------------------------=== #


struct _AcceptFutureState(_FutureCallback):
    """Internal state for a single async accept operation.

    Implements _FutureCallback so the io_uring trampoline can dispatch
    CQE results into this struct. Stored on the heap; the Completion's
    context pointer points back to the enclosing _AcceptFutureState.

    Fields:
        completion: The io_uring completion token (fn ptr + context ptr).
        _socket_fd: The accepted socket fd (-1 = not yet set).
        _error_code: The errno on failure (0 = no error).
        done: True once the CQE callback has fired.
        consumed: True once result() has been called.
        _pending_ptr: Points to WatchLoop._pending for decrement on completion.
    """

    var completion: Completion
    var _socket_fd: Int32
    var _error_code: Int32
    var done: Bool
    var consumed: Bool
    var _pending_ptr: Pointer[Int, MutUntrackedOrigin]

    def __init__(
        out self, _pending_ptr: Pointer[Int, MutUntrackedOrigin]
    ):
        """Construct an _AcceptFutureState with a pending-counter pointer.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context after heap allocation.

        Args:
            _pending_ptr: Pointer to the WatchLoop's pending counter.
        """
        self.completion = Completion()
        self._socket_fd = Int32(-1)
        self._error_code = Int32(0)
        self.done = False
        self.consumed = False
        self._pending_ptr = _pending_ptr

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
        self._pending_ptr = move._pending_ptr

    def set_result(mut self, result: Int32):
        """Store the CQE result from io_uring accept.

        On success (result >= 0), stores the accepted fd.
        On failure (result < 0), stores the negated errno.
        Decrements the WatchLoop pending counter.

        Args:
            result: The io_uring CQE result (accepted fd or negative errno).
        """
        if result >= 0:
            self._socket_fd = result
        else:
            self._error_code = -result
        self.done = True
        self._pending_ptr[] -= 1


# ===----------------------------------------------------------------------=== #
# AcceptFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct AcceptFuture(Movable):
    """RAII handle for an in-flight async accept operation.

    Owns a heap-allocated _AcceptFutureState. Call done() to check
    completion, then result() to extract the accepted Socket.

    If dropped without calling result() and the accept succeeded,
    the accepted fd is closed to prevent resource leaks.
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
        """Release the heap-allocated state.

        If the accept succeeded but result() was never called,
        closes the accepted fd to prevent resource leaks.
        """
        # Close unclaimed accepted fd to prevent leak.
        if not self._state[].consumed and self._state[]._socket_fd >= 0:
            close_unchecked(unsafe_fd=self._state[]._socket_fd)
        self._state.unsafe_deinit_pointee()
        self._state.unsafe_free()

    def result(mut self) raises -> Socket:
        """Extract the accepted Socket from a completed accept.

        Consumes the result — a second call raises. The returned Socket
        owns the accepted fd; the AcceptFuture no longer closes it on drop.

        Returns:
            The accepted Socket wrapping an OwnedHandle.

        Raises:
            If the result was already consumed, the operation has not
            completed, or the accept syscall returned an error.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            raise "operation not complete"
        self._state[].consumed = True
        if self._state[]._error_code != Int32(0):
            raise String(
                "accept failed: errno ", Int(self._state[]._error_code)
            )
        return Socket(OwnedHandle(raw=self._state[]._socket_fd))

    def done(self) -> Bool:
        """Return True if the accept operation has completed.

        Returns:
            True once the CQE callback has fired (success or failure).
        """
        return self._state[].done
