"""TimerFuture — async timeout via WatchLoop.

_TimerFutureState holds the per-operation Completion token and a
Timeout (for pointer stability — the operation points to it).
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
from boucle.watch._callback import _FutureCallback, _SlotLink, _dispatch


# ===----------------------------------------------------------------------=== #
# _TimerFutureState — internal, slab-owned per-operation state
# ===----------------------------------------------------------------------=== #


struct _TimerFutureState(_FutureCallback):
    """Internal state for a single async timeout operation.

    Implements _FutureCallback so the generic _dispatch can deliver
    completion results into this struct and the WatchLoop registry can settle
    its ownership. The Timeout (layout-compatible with
    Timeout) is stored here for pointer stability — the operation
    points to it and it must remain valid until the completion fires.
    """

    var completion: Completion
    var _ts: Timeout
    var _expired: Bool
    var done: Bool
    var consumed: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(out self, ts: Timeout):
        """Construct a _TimerFutureState with a timeout.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context once the state is in its slot.

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
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        self.completion = move.completion^
        self._ts = move._ts
        self._expired = move._expired
        self.done = move.done
        self.consumed = move.consumed
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def set_result(mut self, result: Int):
        """Store the completion result from timeout operation and mark done.

        -ETIME (-62) means the timer expired normally. Any other result
        (e.g. 0 for cancellation) means it did not expire.
        """
        self._expired = result == -62
        self.done = True

    def is_done(self) -> Bool:
        """Return True once the completion callback has fired.
        """
        return self.done

    def owner_dropped(self) -> Bool:
        """Return True if the TimerFuture was dropped before completion.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this timer armed."""
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
# TimerFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct TimerFuture(Movable):
    """RAII handle for an in-flight async timeout operation.

    Points at a slab-owned _TimerFutureState. Call done() to check
    completion, then result() to check if the timer expired. Dropping
    the future before completion is safe, as is destroying the loop
    before completion (result() then raises).
    """

    var _state: Pointer[_TimerFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_TimerFutureState, MutUntrackedOrigin],
    ):
        """Construct a TimerFuture wrapping a slab-owned state.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the loop has already been destroyed, this handle is the last
        reader of the state and destroys its contents here; the slot
        memory stays with the leaked slab. Otherwise the state is marked
        as orphaned (the operation may still point at `_ts`) and the
        loop's slab releases it — at the sweep after the completion
        arrives, or when the loop itself is destroyed.
        """
        if self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
        else:
            self._state[].mark_owner_dropped()

    def result(mut self) raises -> Bool:
        """Return whether the timer expired.

        Consumes the result — a second call raises.

        Returns:
            True if the timer expired normally, False if cancelled.

        Raises:
            A plain message if the result was already consumed, the loop
            was destroyed before the timer fired, or the operation has
            not completed. A cancelled timer is not an exception here —
            it comes back as False.
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
        """
        return self._state[].done
