"""TimerFuture — async timeout via WatchLoop, with cancel and reset.

`_TimerFutureState` owns the timer's `Completion`, its `Timeout` (the
operation points to it, so it must not move) and two more completions
for the internal operations a handle can ask for: a cancel
(`ASYNC_CANCEL` on io_uring, heap removal on epoll) and a re-arm
(`TIMEOUT_REMOVE` with `IORING_TIMEOUT_UPDATE` on io_uring, heap
update on epoll). `TimerFuture` is the RAII handle returned to callers.

Requests are deferred: `cancel()` and `reset()` only set a flag and
push the slot key on the loop's deferred list; `WatchLoop.step()` and
`run()` flush it before and after each tick and the state submits
then. The timer's own completion is the only observable one and is
counted in the loop's `_pending`; the cancel and update completions
are tallied as internal through `_LoopShared` so `step()` never
reports them. The slot settles once the timer's terminal and every
submitted internal completion have arrived, in whichever order they
land (on io_uring the cancel's CQE can precede the target's
-ECANCELED).

Dropping the handle never cancels the timer: an armed timer keeps
`run()` alive until it fires, and the loop releases the slot then.
Destroying the loop first is also safe: the handle destroys the state
on drop and `result()` reports the destroyed loop.
"""

from std.memory import Pointer

from boucle.drivers import _WatchDriver
from boucle.error import IOError
from boucle.proactor.completion import Completion
from boucle.socle.platform import ETIME
from boucle.timeout import Timeout
from boucle.watch._callback import _InFlightState, _SlotLink
from boucle.watch._shared import _LoopShared


# Largest duration `WatchLoop.timeout` and `TimerFuture.reset` accept, in
# milliseconds: the bound the epoll driver clamps its wait to, so a timer
# is never armed for longer than one tick can wait for it.
comptime _MAX_TIMEOUT_MS = Int(Int32.MAX)


# ===----------------------------------------------------------------------=== #
# _TimerFutureState — internal, slab-owned per-operation state
# ===----------------------------------------------------------------------=== #


struct _TimerFutureState(_InFlightState):
    """Slab-owned state of one kernel timer and its deferred cancel or re-arm.

    `_ts` is what the timer was armed with; `_ts_next` is the one slot
    every not-yet-entered update reads from, so resets before a flush
    collapse to the last value. `internal_in_flight` counts cancel and
    update ops submitted whose completion has not arrived; the slot is
    reclaimable only when it is zero and the timer is done.
    """

    var completion: Completion
    var cancel_completion: Completion
    var update_completion: Completion
    var _ts: Timeout
    var _ts_next: Timeout
    var _shared: Pointer[_LoopShared, MutUntrackedOrigin]
    var _expired: Bool
    var done: Bool
    var consumed: Bool
    var cancel_requested: Bool
    var cancel_submitted: Bool
    var reset_requested: Bool
    var internal_in_flight: Int
    var _deferred_queued: Bool
    var _settled: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(
        out self,
        ts: Timeout,
        shared: Pointer[_LoopShared, MutUntrackedOrigin],
    ):
        """Construct an armed timer state; call `wire()` once it is in its slot.

        Args:
            ts: The duration the timer is armed with; the driver points
                the operation at the copy stored here.
            shared: The loop's shared box (deferred queue, internal tally).
        """
        self.completion = Completion()
        self.cancel_completion = Completion()
        self.update_completion = Completion()
        self._ts = ts
        self._ts_next = Timeout()
        self._shared = shared
        self._expired = False
        self.done = False
        self.consumed = False
        self.cancel_requested = False
        self.cancel_submitted = False
        self.reset_requested = False
        self.internal_in_flight = 0
        self._deferred_queued = False
        self._settled = False
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        self.completion = move.completion^
        self.cancel_completion = move.cancel_completion^
        self.update_completion = move.update_completion^
        self._ts = move._ts
        self._ts_next = move._ts_next
        self._shared = move._shared
        self._expired = move._expired
        self.done = move.done
        self.consumed = move.consumed
        self.cancel_requested = move.cancel_requested
        self.cancel_submitted = move.cancel_submitted
        self.reset_requested = move.reset_requested
        self.internal_in_flight = move.internal_in_flight
        self._deferred_queued = move._deferred_queued
        self._settled = move._settled
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def wire(mut self):
        """Point the three completions at this slot.

        Must run after the slab placed the state and before the timer is
        submitted: the addresses recorded are those of the slot, which
        never moves.
        """
        var ctx = Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self))
        )
        self.completion = Completion(Self._on_timer_cb, ctx)
        self.cancel_completion = Completion(Self._on_cancel_cb, ctx)
        self.update_completion = Completion(Self._on_update_cb, ctx)

    def completion_ptr(mut self) -> Pointer[Completion, MutUntrackedOrigin]:
        """Pointer to the timer's Completion for the driver."""
        return Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self.completion))
        )

    def cancel_ptr(mut self) -> Pointer[Completion, MutUntrackedOrigin]:
        """Pointer to the cancel's Completion for the driver."""
        return Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self.cancel_completion))
        )

    def update_ptr(mut self) -> Pointer[Completion, MutUntrackedOrigin]:
        """Pointer to the update's Completion for the driver."""
        return Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self.update_completion))
        )

    def ts_ptr(mut self) -> Pointer[NoneType, MutUntrackedOrigin]:
        """Opaque pointer to the armed duration for the driver."""
        return Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._ts))
        )

    def ts_next_ptr(mut self) -> Pointer[NoneType, MutUntrackedOrigin]:
        """Opaque pointer to the pending re-arm duration for the driver."""
        return Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._ts_next))
        )

    def request_cancel(mut self) -> Bool:
        """Queue a cancel; False when nothing can be cancelled any more.

        `_loop_gone` is tested before anything reaches `_shared`, which
        the loop frees with itself. A reset still waiting on the
        deferred list is dropped in favour of the cancel.
        """
        if self._loop_gone or self.done:
            return False
        if self.cancel_requested or self.cancel_submitted:
            return False
        self.reset_requested = False
        self.cancel_requested = True
        self._queue_deferred()
        return True

    def request_reset(mut self, timeout_ms: UInt64) -> Bool:
        """Queue a re-arm for `timeout_ms`; False when the timer cannot be re-armed.

        Refused once the timer is done, after a cancel was requested or
        submitted, above `_MAX_TIMEOUT_MS`, or once the loop is gone.
        `_ts_next` is shared by every update not yet entered into the
        kernel: a second call before the flush overwrites it, and a call
        after the flush wrote an SQE but before the enter changes what
        that SQE carries (harmless, last wins). A call while an update
        is in flight queues another; the kernel applies them in order.
        """
        if self._loop_gone or self.done:
            return False
        if self.cancel_requested or self.cancel_submitted:
            return False
        if timeout_ms > UInt64(_MAX_TIMEOUT_MS):
            return False
        self._ts_next = Timeout.from_ms(Int64(timeout_ms))
        self.reset_requested = True
        self._queue_deferred()
        return True

    def _queue_deferred(mut self):
        """Push the slot key on the loop's deferred list (once per flush)."""
        if not self._deferred_queued:
            self._deferred_queued = True
            self._shared[].deferred[].append(self._link.key)

    def _refused(mut self):
        """Drop the pending request; the timer stays armed and fires normally."""
        self.cancel_requested = False
        self.reset_requested = False

    def _submission_failed(mut self, e: Error):
        """Re-queue on a full submission queue, give up on anything else.

        Args:
            e: The error the driver raised; EAGAIN in socle's
               negated-errno text is the one refusal that is retried.
        """
        if IOError.from_error(e).is_would_block():
            self._queue_deferred()
        else:
            self._refused()

    def _maybe_settle(mut self):
        """Release the slot once the timer ended and no internal op is in flight.

        The only caller of `_link.completed`; `_settled` makes it run
        once whichever completion arrives last.
        """
        if self.done and self.internal_in_flight == 0 and not self._settled:
            self._settled = True
            self._link.completed(self._owner_dropped)

    def _on_internal_done(mut self):
        """Account one cancel or update completion; its result is ignored."""
        self._shared[].internal_completions += 1
        self.internal_in_flight -= 1
        self._maybe_settle()

    def flush_deferred(mut self, mut driver: _WatchDriver):
        """Submit the deferred cancel or re-arm, whichever is requested.

        Called by the loop outside completion processing. A cancel wins
        over a re-arm. A submission refused because the queue is still
        full after the driver's own flush stays requested and re-queues
        the key; any other refusal drops the request (`_refused`) and
        the timer proceeds untouched. Neither driver refuses for another
        reason today (`IoUringDriver` raises only on a full queue, the
        epoll driver never raises), so that branch is defensive. Never
        raises.

        Args:
            driver: The loop's driver.
        """
        self._deferred_queued = False
        if self.cancel_requested:
            try:
                driver.cancel(self.completion_ptr(), self.cancel_ptr())
                self.cancel_requested = False
                self.cancel_submitted = True
                self.internal_in_flight += 1
            except e:
                self._submission_failed(e)
            return
        if self.reset_requested:
            try:
                driver.timeout_update(
                    self.ts_next_ptr(), self.completion_ptr(), self.update_ptr()
                )
                self.reset_requested = False
                self.internal_in_flight += 1
            except e:
                self._submission_failed(e)

    @staticmethod
    def _on_timer_cb(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """The timer's terminal: -ETIME expired, anything else (-ECANCELED) did not.

        A request still waiting on the deferred list is dropped: there
        is nothing left to cancel or re-arm, and the flush ignores a
        cleared request.

        Args:
            ctx: Pointer to the owning `_TimerFutureState`.
            result: -ETIME, -ECANCELED, or 0.
            flags: Unused.
        """
        var st = ctx.unsafe_bitcast[_TimerFutureState]()
        st[]._expired = result == -Int(ETIME)
        st[].done = True
        st[].cancel_requested = False
        st[].reset_requested = False
        st[]._maybe_settle()

    @staticmethod
    def _on_cancel_cb(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """The cancel's own completion: 0, -ENOENT and -EALREADY are all fine.

        Args:
            ctx: Pointer to the owning `_TimerFutureState`.
            result: Ignored.
            flags: Ignored.
        """
        ctx.unsafe_bitcast[_TimerFutureState]()[]._on_internal_done()

    @staticmethod
    def _on_update_cb(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """The update's own completion: 0, -ENOENT and -EALREADY are all fine.

        Args:
            ctx: Pointer to the owning `_TimerFutureState`.
            result: Ignored.
            flags: Ignored.
        """
        ctx.unsafe_bitcast[_TimerFutureState]()[]._on_internal_done()

    # ── _InFlightState ───────────────────────────────────────────────────

    def is_done(self) -> Bool:
        """True when no completion can write this state again."""
        return self.done and self.internal_in_flight == 0

    def owner_dropped(self) -> Bool:
        """True if the TimerFuture was dropped."""
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """True if the WatchLoop was destroyed with this timer armed."""
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the loop is gone; `cancel()` and `reset()` refuse from here on."""
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Record the slot this state lives in and the queue to notify."""
        self._link = link

    def notify_done(self):
        """Inert: the timer settles through `_maybe_settle`, never through this hook."""
        pass

    def mark_owner_dropped(mut self):
        """Record that the handle let go; queue the slot if nothing is in flight."""
        self._owner_dropped = True
        self._link.dropped(self.is_done())


# ===----------------------------------------------------------------------=== #
# TimerFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct TimerFuture(Movable):
    """RAII handle for an in-flight async timeout operation.

    Points at a slab-owned _TimerFutureState. Call done() to check
    completion, then result() to check if the timer expired; cancel()
    and reset() ask the loop to cancel or re-arm it at its next tick.
    Dropping the future before completion is safe and does not cancel
    the timer, as is destroying the loop before completion (result()
    then raises).
    """

    var _state: Pointer[_TimerFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_TimerFutureState, MutUntrackedOrigin],
    ):
        """Construct a TimerFuture wrapping a slab-owned state."""
        self._state = state

    def __init__(out self, *, deinit move: Self):
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the loop has already been destroyed, this handle is the last
        reader of the state and destroys its contents here; the slot
        memory stays with the leaked slab. Otherwise the state is marked
        as orphaned (the operation may still point at `_ts`) and the
        loop's slab releases it — at the sweep after every completion
        arrived, or when the loop itself is destroyed.
        """
        if self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
        else:
            self._state[].mark_owner_dropped()

    def cancel(mut self) -> Bool:
        """Ask the loop to cancel the timer at its next `step()` or `run()`.

        Deferred, never raises. Returns False (and does nothing) when the
        timer already completed, a cancel was already requested or
        submitted, or the loop is gone. A pending `reset` not yet
        submitted is dropped. After the cancel completes, `result()`
        returns False; if the timer expired before the cancel reached the
        kernel, `result()` returns True.
        """
        return self._state[].request_cancel()

    def reset(mut self, timeout_ms: UInt64) -> Bool:
        """Ask the loop to re-arm the timer for `timeout_ms` from the moment the request reaches the kernel (the next `step()` or `run()`).

        Deferred, never raises. Returns False (and does nothing) when the
        timer already completed, a cancel was requested or submitted, or
        `timeout_ms` exceeds Int32.MAX, or the loop is gone; arm a new
        `timeout()` then. Resets not yet flushed collapse to the last
        value. A reset issued after the timer expired but before its
        completion was observed is lost: the timer reports True from its
        old deadline. One submission and one completion per reset on
        io_uring (IORING_OP_TIMEOUT_REMOVE with IORING_TIMEOUT_UPDATE); a
        heap update on epoll.
        """
        return self._state[].request_reset(timeout_ms)

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
        """True once the timer's own terminal completion arrived (expiry or -ECANCELED).

        The slot may outlive it while a cancel or reset completion is
        still in flight; that is invisible to the caller. Stays False
        forever if the loop was destroyed first; result() then raises
        with the reason.
        """
        return self._state[].done
