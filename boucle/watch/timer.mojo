"""TimerFuture — async timeout via WatchLoop.

_TimerFutureState holds the per-operation Completion token and a
__kernel_timespec (for pointer stability — the SQE points to it).
TimerFuture is the RAII handle returned to callers.

The state is shared with the WatchLoop that armed the timer (see
`_callback.mojo` for the ownership rules). Dropping the TimerFuture
before the timer fires is safe: the loop frees the state once it is
done or when the loop itself is destroyed. Destroying the loop before
the timer fires is also safe: the future frees the state on drop and
result() reports the destroyed loop.
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
    CQE results into this struct and the WatchLoop registry can settle
    its ownership. The Timeout (layout-compatible with
    __kernel_timespec) is stored here for pointer stability — the SQE
    points to it and it must remain valid until the CQE fires.

    Fields:
        completion: The io_uring completion token (fn ptr + context ptr).
        _ts: Timeout value (layout-identical to __kernel_timespec).
        _expired: True if the timer expired normally (CQE result == -ETIME).
        done: True once the CQE callback has fired.
        consumed: True once result() has been called.
        _owner_dropped: True if the TimerFuture was dropped before done;
                        the WatchLoop then frees this state.
        _loop_gone: True if the WatchLoop was destroyed before done;
                    the TimerFuture then frees this state.
    """

    var completion: Completion
    var _ts: Timeout
    var _expired: Bool
    var done: Bool
    var consumed: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool

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
        self._owner_dropped = False
        self._loop_gone = False

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
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone

    def set_result(mut self, result: Int):
        """Store the CQE result from io_uring timeout and mark done.

        -ETIME (-62) means the timer expired normally. Any other result
        (e.g. 0 for cancellation) means it did not expire.

        Args:
            result: The io_uring CQE result (-62 = expired, 0 = cancelled).
        """
        self._expired = result == -62
        self.done = True

    def is_done(self) -> Bool:
        """Return True once the CQE callback has fired.

        Returns:
            True if no callback will write this state again.
        """
        return self.done

    def owner_dropped(self) -> Bool:
        """Return True if the TimerFuture was dropped before completion.

        Returns:
            True if the WatchLoop must free this state.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        Returns:
            True if the TimerFuture is the sole remaining owner.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this timer armed."""
        self._loop_gone = True


# ===----------------------------------------------------------------------=== #
# TimerFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct TimerFuture(Movable):
    """RAII handle for an in-flight async timeout operation.

    Owns a heap-allocated _TimerFutureState. Call done() to check
    completion, then result() to check if the timer expired. Dropping
    the future before completion is safe, as is destroying the loop
    before completion (result() then raises).
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
        """Release the state, or hand it over to the WatchLoop.

        If the completion has been delivered, or the loop has already
        been destroyed, this handle is the last owner and frees the
        state. Otherwise the loop still tracks the state (and the SQE
        may still point at `_ts`), so it is marked as orphaned and the
        loop frees it — after the CQE arrives during run(), or when the
        loop itself is destroyed.
        """
        if self._state[].done or self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
            self._state.unsafe_free()
        else:
            self._state[]._owner_dropped = True

    def result(mut self) raises -> Bool:
        """Return whether the timer expired.

        Consumes the result — a second call raises.

        Returns:
            True if the timer expired normally, False if cancelled.

        Raises:
            If the result was already consumed, the loop was destroyed
            before the timer fired, or the operation has not completed.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            if self._state[]._loop_gone:
                raise "loop destroyed before completion"
            raise "operation not complete"
        self._state[].consumed = True
        return self._state[]._expired

    def done(self) -> Bool:
        """Return True if the timeout operation has completed.

        Stays False forever if the loop was destroyed first; result()
        then raises with the reason.

        Returns:
            True once the CQE callback has fired.
        """
        return self._state[].done
