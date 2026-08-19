"""RecvFuture — async recv via WatchLoop.

_RecvFutureState holds the per-operation Completion token and the raw
CQE result (bytes read or negative errno). RecvFuture is the RAII
handle returned to callers.

Warning: The buffer passed to WatchLoop.recv() is NOT owned by the
FutureState. The caller must ensure the buffer remains valid until
run() completes.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.proactor.completion import Completion
from boucle.watch._callback import _FutureCallback, _trampoline


# ===----------------------------------------------------------------------=== #
# _RecvFutureState — internal, heap-allocated per-operation state
# ===----------------------------------------------------------------------=== #


struct _RecvFutureState(_FutureCallback):
    """Internal state for a single async recv operation.

    Implements _FutureCallback so the io_uring trampoline can dispatch
    CQE results into this struct.

    Fields:
        completion: The io_uring completion token (fn ptr + context ptr).
        _cqe_result: Raw CQE result (bytes read >= 0, or negative errno).
        done: True once the CQE callback has fired.
        consumed: True once result() has been called.
        _pending_ptr: Points to WatchLoop._pending for decrement on completion.
    """

    var completion: Completion
    var _cqe_result: Int32
    var done: Bool
    var consumed: Bool
    var _pending_ptr: Pointer[Int, MutUntrackedOrigin]

    def __init__(
        out self, _pending_ptr: Pointer[Int, MutUntrackedOrigin]
    ):
        """Construct a _RecvFutureState with a pending-counter pointer.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context after heap allocation.

        Args:
            _pending_ptr: Pointer to the WatchLoop's pending counter.
        """
        self.completion = Completion()
        self._cqe_result = Int32(0)
        self.done = False
        self.consumed = False
        self._pending_ptr = _pending_ptr

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source state to move from.
        """
        self.completion = move.completion^
        self._cqe_result = move._cqe_result
        self.done = move.done
        self.consumed = move.consumed
        self._pending_ptr = move._pending_ptr

    def set_result(mut self, result: Int32):
        """Store the raw CQE result from io_uring recv.

        Args:
            result: The io_uring CQE result (bytes read >= 0, or
                    negative errno on failure).
        """
        self._cqe_result = result
        self.done = True
        self._pending_ptr[] -= 1


# ===----------------------------------------------------------------------=== #
# RecvFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct RecvFuture(Movable):
    """RAII handle for an in-flight async recv operation.

    Owns a heap-allocated _RecvFutureState. Call done() to check
    completion, then result() to extract the byte count.

    The buffer is NOT owned by this future — the caller must keep it
    alive until run() completes.
    """

    var _state: Pointer[_RecvFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_RecvFutureState, MutUntrackedOrigin],
    ):
        """Construct a RecvFuture wrapping a heap-allocated state.

        Args:
            state: Pointer to the heap-allocated _RecvFutureState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source RecvFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the heap-allocated state."""
        self._state.unsafe_deinit_pointee()
        self._state.unsafe_free()

    def result(mut self) raises -> Int:
        """Extract the number of bytes received.

        Consumes the result — a second call raises. Returns 0 for EOF.
        Raises on negative CQE result (kernel error).

        Returns:
            The number of bytes received (0 = EOF).

        Raises:
            If the result was already consumed, the operation has not
            completed, or the recv syscall returned an error.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            raise "operation not complete"
        self._state[].consumed = True
        if self._state[]._cqe_result < 0:
            raise String(
                "recv failed: errno ",
                Int(-self._state[]._cqe_result),
            )
        return Int(self._state[]._cqe_result)

    def done(self) -> Bool:
        """Return True if the recv operation has completed.

        Returns:
            True once the CQE callback has fired (success or failure).
        """
        return self._state[].done
