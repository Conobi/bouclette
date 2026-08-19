"""TimerFuture — async timeout via WatchLoop.

_TimerFutureState holds the per-operation Completion token and a
__kernel_timespec (for pointer stability — the SQE points to it).
TimerFuture is the RAII handle returned to callers.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.proactor.completion import Completion
from boucle.timeout import Timeout
from boucle.watch._callback import _FutureCallback, _dispatch


# ===----------------------------------------------------------------------=== #
# _TimerFutureState — internal, heap-allocated per-operation state
# ===----------------------------------------------------------------------=== #


struct _TimerFutureState(_FutureCallback):
    """Internal state for a single async timeout operation.

    Implements _FutureCallback so the generic _dispatch can deliver
    CQE results into this struct. The Timeout (layout-compatible with
    __kernel_timespec) is stored here for pointer stability — the SQE
    points to it and it must remain valid until the CQE fires.

    Fields:
        completion: The io_uring completion token (fn ptr + context ptr).
        _ts: Timeout value (layout-identical to __kernel_timespec).
        _expired: True if the timer expired normally (CQE result == -ETIME).
        done: True once the CQE callback has fired.
        consumed: True once result() has been called.
    """

    var completion: Completion
    var _ts: Timeout
    var _expired: Bool
    var done: Bool
    var consumed: Bool

    def __init__(out self, ts: Timeout):
        """Construct a _TimerFutureState with a timeout.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context after heap allocation.

        Args:
            ts: The timeout duration (seconds + nanoseconds).
        """
        self.completion = Completion()
        self._ts = ts
        self._expired = False
        self.done = False
        self.consumed = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source state to move from.
        """
        self.completion = move.completion^
        self._ts = move._ts
        self._expired = move._expired
        self.done = move.done
        self.consumed = move.consumed

    def set_result(mut self, result: Int32):
        """Store the CQE result from io_uring timeout.

        -ETIME (-62) means the timer expired normally. Any other result
        (e.g. 0 for cancellation) means it did not expire.

        Args:
            result: The io_uring CQE result (-62 = expired, 0 = cancelled).
        """
        self._expired = result == Int32(-62)
        self.done = True


# ===----------------------------------------------------------------------=== #
# TimerFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct TimerFuture(Movable):
    """RAII handle for an in-flight async timeout operation.

    Owns a heap-allocated _TimerFutureState. Call done() to check
    completion, then result() to check if the timer expired.
    """

    var _state: Pointer[_TimerFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_TimerFutureState, MutUntrackedOrigin],
    ):
        """Construct a TimerFuture wrapping a heap-allocated state.

        Args:
            state: Pointer to the heap-allocated _TimerFutureState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source TimerFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the heap-allocated state."""
        self._state.unsafe_deinit_pointee()
        self._state.unsafe_free()

    def result(mut self) raises -> Bool:
        """Return whether the timer expired.

        Consumes the result — a second call raises.

        Returns:
            True if the timer expired normally, False if cancelled.

        Raises:
            If the result was already consumed or the operation has not
            completed.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            raise "operation not complete"
        self._state[].consumed = True
        return self._state[]._expired

    def done(self) -> Bool:
        """Return True if the timeout operation has completed.

        Returns:
            True once the CQE callback has fired.
        """
        return self._state[].done
