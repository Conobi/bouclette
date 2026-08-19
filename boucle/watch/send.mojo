"""SendFuture — async send via WatchLoop.

_SendFutureState holds the per-operation Completion token and the raw
CQE result (bytes written or negative errno). SendFuture is the RAII
handle returned to callers.

Warning: The buffer passed to WatchLoop.send() is NOT owned by the
FutureState. The caller must ensure the buffer remains valid until
run() completes.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.proactor.completion import Completion
from boucle.watch._callback import _FutureCallback, _trampoline


# ===----------------------------------------------------------------------=== #
# _SendFutureState — internal, heap-allocated per-operation state
# ===----------------------------------------------------------------------=== #


struct _SendFutureState(_FutureCallback):
    """Internal state for a single async send operation.

    Implements _FutureCallback so the io_uring trampoline can dispatch
    CQE results into this struct.

    Fields:
        completion: The io_uring completion token (fn ptr + context ptr).
        _cqe_result: Raw CQE result (bytes written >= 0, or negative errno).
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
        """Construct a _SendFutureState with a pending-counter pointer.

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
        """Store the raw CQE result from io_uring send.

        Args:
            result: The io_uring CQE result (bytes written >= 0, or
                    negative errno on failure).
        """
        self._cqe_result = result
        self.done = True
        self._pending_ptr[] -= 1


# ===----------------------------------------------------------------------=== #
# SendFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct SendFuture(Movable):
    """RAII handle for an in-flight async send operation.

    Owns a heap-allocated _SendFutureState. Call done() to check
    completion, then result() to extract the byte count.

    The buffer is NOT owned by this future — the caller must keep it
    alive until run() completes.
    """

    var _state: Pointer[_SendFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_SendFutureState, MutUntrackedOrigin],
    ):
        """Construct a SendFuture wrapping a heap-allocated state.

        Args:
            state: Pointer to the heap-allocated _SendFutureState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source SendFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the heap-allocated state."""
        self._state.unsafe_deinit_pointee()
        self._state.unsafe_free()

    def result(mut self) raises -> Int:
        """Extract the number of bytes sent.

        Consumes the result — a second call raises. Raises on negative
        CQE result (kernel error).

        Returns:
            The number of bytes sent.

        Raises:
            If the result was already consumed, the operation has not
            completed, or the send syscall returned an error.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            raise "operation not complete"
        self._state[].consumed = True
        if self._state[]._cqe_result < 0:
            raise String(
                "send failed: errno ",
                Int(-self._state[]._cqe_result),
            )
        return Int(self._state[]._cqe_result)

    def done(self) -> Bool:
        """Return True if the send operation has completed.

        Returns:
            True once the CQE callback has fired (success or failure).
        """
        return self._state[].done
