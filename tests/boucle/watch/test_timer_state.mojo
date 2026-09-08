"""`_TimerFutureState` driven by hand-fired completions, no loop and no kernel timer.

Heap-allocated shared, deferred, settle and live boxes are created per
test. The state's three static callbacks are invoked as a driver would.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true

from boucle.drivers.auto import AutoDriver
from boucle.drivers.backend import Backend
from boucle.socle.platform import EAGAIN, ECANCELED, EINVAL, ETIME
from boucle.timeout import Timeout
from boucle.watch._callback import _KIND_BITS, _SlotLink
from boucle.watch._shared import _LoopShared
from boucle.watch.timer import _MAX_TIMEOUT_MS, _TimerFutureState

comptime TIMER_KEY = (2 << _KIND_BITS) | 5
comptime EV_TIMER = 0
comptime EV_UPDATE = 1
comptime EV_CANCEL = 2


# ===----------------------------------------------------------------------=== #
# Helpers
# ===----------------------------------------------------------------------=== #


def _ctx(
    state: Pointer[_TimerFutureState, MutUntrackedOrigin],
) -> Pointer[NoneType, MutUntrackedOrigin]:
    """The erased context the completions carry."""
    return state.unsafe_bitcast[NoneType]()


def _fire_timer(
    state: Pointer[_TimerFutureState, MutUntrackedOrigin], result: Int
):
    """Deliver the timer's terminal as a driver would."""
    _TimerFutureState._on_timer_cb(_ctx(state), result, UInt32(0))


def _fire_cancel(
    state: Pointer[_TimerFutureState, MutUntrackedOrigin], result: Int
):
    """Deliver the cancel's own completion."""
    _TimerFutureState._on_cancel_cb(_ctx(state), result, UInt32(0))


def _fire_update(
    state: Pointer[_TimerFutureState, MutUntrackedOrigin], result: Int
):
    """Deliver the update's own completion."""
    _TimerFutureState._on_update_cb(_ctx(state), result, UInt32(0))


def _submit_cancel(
    state: Pointer[_TimerFutureState, MutUntrackedOrigin],
) raises:
    """Request a cancel and pretend the flush submitted it."""
    assert_true(state[].request_cancel(), "cancel accepted")
    state[].cancel_requested = False
    state[].cancel_submitted = True
    state[].internal_in_flight += 1
    state[]._deferred_queued = False


def _submit_update(
    state: Pointer[_TimerFutureState, MutUntrackedOrigin],
) raises:
    """Request a re-arm and pretend the flush submitted it."""
    assert_true(state[].request_reset(10), "reset accepted")
    state[].reset_requested = False
    state[].internal_in_flight += 1
    state[]._deferred_queued = False


struct _Ptrs(TrivialRegisterPassable):
    """The five pointers `_new_fx` allocates, passed as one value."""

    var state: Pointer[_TimerFutureState, MutUntrackedOrigin]
    var shared: Pointer[_LoopShared, MutUntrackedOrigin]
    var deferred: Pointer[List[Int], MutUntrackedOrigin]
    var settle: Pointer[List[Int], MutUntrackedOrigin]
    var live: Pointer[Int, MutUntrackedOrigin]

    @always_inline
    def __init__(
        out self,
        state: Pointer[_TimerFutureState, MutUntrackedOrigin],
        shared: Pointer[_LoopShared, MutUntrackedOrigin],
        deferred: Pointer[List[Int], MutUntrackedOrigin],
        settle: Pointer[List[Int], MutUntrackedOrigin],
        live: Pointer[Int, MutUntrackedOrigin],
    ):
        """Wrap the five pointers."""
        self.state = state
        self.shared = shared
        self.deferred = deferred
        self.settle = settle
        self.live = live


def _new_fx() -> _Ptrs:
    """Allocate a fresh timer state with all its dependencies."""
    var deferred = unsafe_alloc[List[Int]](1)
    deferred.unsafe_write(List[Int]())
    var settle = unsafe_alloc[List[Int]](1)
    settle.unsafe_write(List[Int]())
    var live = unsafe_alloc[Int](1)
    live.unsafe_write(1)
    var shared = unsafe_alloc[_LoopShared](1)
    shared.unsafe_write(_LoopShared(deferred))
    shared[].driver_alive = False
    var state = unsafe_alloc[_TimerFutureState](1)
    state.unsafe_write(
        _TimerFutureState(Timeout.from_ms(5000), shared)
    )
    state[].wire()
    state[].bind(_SlotLink(TIMER_KEY, settle, live))
    return _Ptrs(state, shared, deferred, settle, live)


def _del_fx(p: _Ptrs):
    """Free everything `_new_fx` allocated."""
    p.state.unsafe_free()
    p.shared.unsafe_free()
    p.live.unsafe_free()
    p.settle.unsafe_deinit_pointee()
    p.settle.unsafe_free()
    p.deferred.unsafe_deinit_pointee()
    p.deferred.unsafe_free()


# ===----------------------------------------------------------------------=== #
# Core ordering test
# ===----------------------------------------------------------------------=== #


def _run_ordering(
    *order: Int, updates: Int, cancels: Int, timer_result: Int
) raises:
    """Submit `updates` then `cancels`, deliver the completions in `order`, settle once."""
    var p = _new_fx()
    var state = p.state
    var shared = p.shared
    var settle = p.settle
    var live = p.live

    for _ in range(updates):
        _submit_update(state)
    for _ in range(cancels):
        _submit_cancel(state)
    assert_equal(state[].internal_in_flight, updates + cancels)
    var n = len(order)
    for i in range(n):
        if order[i] == EV_TIMER:
            _fire_timer(state, timer_result)
        elif order[i] == EV_UPDATE:
            _fire_update(state, 0)
        else:
            _fire_cancel(state, 0)
        if i + 1 < n:
            assert_equal(live[], 1, "settled before the last completion")
            assert_true(not state[].is_done())
            assert_true(not state[]._settled)
    assert_true(state[].done)
    assert_true(state[].is_done())
    assert_true(state[]._settled)
    assert_equal(live[], 0, "live decremented exactly once")
    assert_equal(shared[].internal_completions, updates + cancels)
    assert_equal(len(settle[]), 0, "the handle is still held")
    state[].mark_owner_dropped()
    assert_equal(len(settle[]), 1, "the drop is the second event: one key")
    assert_equal(settle[][0], TIMER_KEY)
    _del_fx(p)


# ===----------------------------------------------------------------------=== #
# Tests
# ===----------------------------------------------------------------------=== #


def test_cancel_orderings() raises:
    """Timer-then-cancel and cancel-then-timer: one key, live once, one internal."""
    _run_ordering(EV_TIMER, EV_CANCEL, updates=0, cancels=1, timer_result=-Int(ECANCELED))
    _run_ordering(EV_CANCEL, EV_TIMER, updates=0, cancels=1, timer_result=-Int(ECANCELED))


def test_update_orderings() raises:
    """Timer-then-update and update-then-timer: same."""
    _run_ordering(EV_TIMER, EV_UPDATE, updates=1, cancels=0, timer_result=-Int(ETIME))
    _run_ordering(EV_UPDATE, EV_TIMER, updates=1, cancels=0, timer_result=-Int(ETIME))


def test_two_updates_in_flight() raises:
    """Two updates (`internal_in_flight == 2`) and the timer, in every order."""
    _run_ordering(EV_TIMER, EV_UPDATE, EV_UPDATE, updates=2, cancels=0, timer_result=-Int(ETIME))
    _run_ordering(EV_UPDATE, EV_TIMER, EV_UPDATE, updates=2, cancels=0, timer_result=-Int(ETIME))
    _run_ordering(EV_UPDATE, EV_UPDATE, EV_TIMER, updates=2, cancels=0, timer_result=-Int(ETIME))


def test_update_then_cancel_in_flight() raises:
    """An update then a cancel in flight, all six orderings with the terminal."""
    _run_ordering(EV_TIMER, EV_UPDATE, EV_CANCEL, updates=1, cancels=1, timer_result=-Int(ECANCELED))
    _run_ordering(EV_TIMER, EV_CANCEL, EV_UPDATE, updates=1, cancels=1, timer_result=-Int(ECANCELED))
    _run_ordering(EV_UPDATE, EV_TIMER, EV_CANCEL, updates=1, cancels=1, timer_result=-Int(ECANCELED))
    _run_ordering(EV_UPDATE, EV_CANCEL, EV_TIMER, updates=1, cancels=1, timer_result=-Int(ECANCELED))
    _run_ordering(EV_CANCEL, EV_TIMER, EV_UPDATE, updates=1, cancels=1, timer_result=-Int(ECANCELED))
    _run_ordering(EV_CANCEL, EV_UPDATE, EV_TIMER, updates=1, cancels=1, timer_result=-Int(ECANCELED))


def test_owner_dropped_before_and_after() raises:
    """The key is pushed exactly once whether the drop or the terminal comes first."""
    var p1 = _new_fx()
    p1.state[].mark_owner_dropped()
    assert_equal(len(p1.settle[]), 0, "not done: nothing to settle yet")
    _fire_timer(p1.state, -Int(ETIME))
    assert_equal(len(p1.settle[]), 1)
    assert_equal(p1.live[], 0)
    _del_fx(p1)

    var p2 = _new_fx()
    _fire_timer(p2.state, -Int(ETIME))
    assert_equal(len(p2.settle[]), 0, "held: not settleable yet")
    assert_equal(p2.live[], 0)
    p2.state[].mark_owner_dropped()
    assert_equal(len(p2.settle[]), 1)
    _del_fx(p2)

    var p3 = _new_fx()
    _submit_cancel(p3.state)
    p3.state[].mark_owner_dropped()
    _fire_cancel(p3.state, 0)
    assert_equal(len(p3.settle[]), 0)
    _fire_timer(p3.state, -Int(ECANCELED))
    assert_equal(len(p3.settle[]), 1)
    assert_equal(p3.live[], 0)
    _del_fx(p3)


def test_request_dropped_by_expiry() raises:
    """A cancel still on the deferred list is dropped by the terminal."""
    var p = _new_fx()
    var state = p.state
    var shared = p.shared
    var deferred = p.deferred
    var settle = p.settle
    var live = p.live
    assert_true(state[].request_cancel())
    assert_true(state[].cancel_requested)
    assert_equal(len(deferred[]), 1)
    assert_equal(deferred[][0], TIMER_KEY)
    _fire_timer(state, -Int(ETIME))
    assert_true(not state[].cancel_requested, "expiry drops the request")
    assert_true(state[].is_done())
    assert_equal(live[], 0)
    var driver = AutoDriver(capacity=4, backend=Backend.EPOLL)
    state[].flush_deferred(driver)
    assert_equal(driver.tick(wait=False), 0, "nothing was submitted")
    assert_equal(shared[].internal_completions, 0)
    assert_equal(state[].internal_in_flight, 0)
    assert_true(not state[].cancel_submitted)
    state[].mark_owner_dropped()
    assert_equal(len(settle[]), 1)
    _del_fx(p)


def test_reset_then_cancel_replaces_the_reset() raises:
    """A cancel requested after a reset drops the reset; the key is queued once."""
    var p = _new_fx()
    var state = p.state
    var deferred = p.deferred
    assert_true(state[].request_reset(10))
    assert_true(state[].reset_requested)
    assert_equal(len(deferred[]), 1)
    assert_true(state[].request_cancel())
    assert_true(not state[].reset_requested)
    assert_true(state[].cancel_requested)
    assert_equal(len(deferred[]), 1, "still one key")
    assert_true(not state[].request_reset(20), "reset refused after a cancel")
    assert_true(not state[].request_cancel(), "second cancel refused")
    _del_fx(p)


def test_refused_then_expiry_settles_once() raises:
    """`_refused` clears the request; the timer proceeds and settles once."""
    var p = _new_fx()
    var state = p.state
    var settle = p.settle
    var live = p.live
    assert_true(state[].request_cancel())
    state[]._refused()
    assert_true(not state[].cancel_requested)
    assert_true(not state[].cancel_submitted)
    assert_equal(state[].internal_in_flight, 0)
    _fire_timer(state, -Int(ETIME))
    assert_true(state[]._expired)
    assert_equal(live[], 0)
    state[].mark_owner_dropped()
    assert_equal(len(settle[]), 1)
    _del_fx(p)


def test_full_queue_requeues_then_expiry() raises:
    """EAGAIN keeps the request and re-queues the key."""
    var p = _new_fx()
    var state = p.state
    var shared = p.shared
    var deferred = p.deferred
    var settle = p.settle
    var live = p.live
    assert_true(state[].request_cancel())
    assert_equal(len(deferred[]), 1)
    state[]._deferred_queued = False
    state[]._submission_failed(Error(String(-EAGAIN)))
    assert_true(state[].cancel_requested, "a full queue keeps the request")
    assert_equal(len(deferred[]), 2, "the key is queued again")
    _fire_timer(state, -Int(ETIME))
    assert_true(not state[].cancel_requested)
    assert_equal(live[], 0)
    var driver = AutoDriver(capacity=4, backend=Backend.EPOLL)
    state[].flush_deferred(driver)
    assert_equal(driver.tick(wait=False), 0, "nothing was submitted")
    assert_equal(shared[].internal_completions, 0)
    state[].mark_owner_dropped()
    assert_equal(len(settle[]), 1)
    _del_fx(p)


def test_other_refusal_drops_the_request() raises:
    """A non-EAGAIN error drops the request without re-queueing."""
    var p = _new_fx()
    var state = p.state
    var deferred = p.deferred
    var settle = p.settle
    assert_true(state[].request_reset(10))
    state[]._deferred_queued = False
    state[]._submission_failed(Error(String(-EINVAL)))
    assert_true(not state[].reset_requested)
    assert_equal(len(deferred[]), 1, "not re-queued")
    assert_equal(state[].internal_in_flight, 0)
    _fire_timer(state, -Int(ETIME))
    assert_true(state[]._expired)
    state[].mark_owner_dropped()
    assert_equal(len(settle[]), 1)
    _del_fx(p)


def test_result_mapping() raises:
    """-ETIME sets `_expired`; -ECANCELED and 0 do not."""
    var p1 = _new_fx()
    _fire_timer(p1.state, -Int(ETIME))
    assert_true(p1.state[]._expired)
    _del_fx(p1)

    var p2 = _new_fx()
    _fire_timer(p2.state, -Int(ECANCELED))
    assert_true(not p2.state[]._expired)
    _del_fx(p2)

    var p3 = _new_fx()
    _fire_timer(p3.state, 0)
    assert_true(not p3.state[]._expired)
    assert_true(p3.state[].done)
    _del_fx(p3)


def test_guards() raises:
    """Done, cancelled, out-of-range and loop-gone states refuse requests."""
    var p1 = _new_fx()
    _fire_timer(p1.state, -Int(ETIME))
    assert_true(not p1.state[].request_cancel())
    assert_true(not p1.state[].request_reset(10))
    assert_equal(len(p1.deferred[]), 0)
    _del_fx(p1)

    var p2 = _new_fx()
    assert_true(not p2.state[].request_reset(UInt64(_MAX_TIMEOUT_MS) + 1))
    assert_equal(len(p2.deferred[]), 0, "nothing queued above the bound")
    assert_true(p2.state[].request_reset(UInt64(_MAX_TIMEOUT_MS)))
    assert_true(p2.state[].request_reset(0), "reset(0) is legal")
    assert_equal(p2.state[]._ts_next.seconds, 0)
    assert_equal(p2.state[]._ts_next.nanoseconds, 0)
    assert_equal(len(p2.deferred[]), 1, "collapsed to one key")
    _del_fx(p2)

    var p3 = _new_fx()
    assert_true(p3.state[].request_reset(5000))
    assert_true(p3.state[].request_reset(10))
    assert_equal(p3.state[]._ts_next.seconds, 0)
    assert_equal(p3.state[]._ts_next.nanoseconds, 10_000_000, "last value wins")
    assert_equal(len(p3.deferred[]), 1)
    _del_fx(p3)

    var p4 = _new_fx()
    p4.state[].mark_loop_gone()
    assert_true(not p4.state[].request_cancel())
    assert_true(not p4.state[].request_reset(10))
    assert_true(not p4.state[].done)
    _del_fx(p4)


def test_notify_done_is_inert() raises:
    """`notify_done` no longer settles; only `_maybe_settle` touches the link."""
    var p = _new_fx()
    p.state[].notify_done()
    assert_equal(p.live[], 1)
    assert_equal(len(p.settle[]), 0)
    _fire_timer(p.state, -Int(ETIME))
    p.state[].notify_done()
    assert_equal(p.live[], 0, "still decremented once")
    assert_equal(len(p.settle[]), 0)
    _del_fx(p)


def test_flush_submits_through_a_driver() raises:
    """The real flush path: cancel and update reach the driver."""
    var driver = AutoDriver(capacity=4, backend=Backend.EPOLL)

    var p1 = _new_fx()
    assert_true(p1.state[].request_cancel())
    p1.state[].flush_deferred(driver)
    assert_true(p1.state[].cancel_submitted)
    assert_true(not p1.state[].cancel_requested)
    assert_true(not p1.state[]._deferred_queued)
    assert_equal(p1.state[].internal_in_flight, 1)
    assert_equal(driver.tick(wait=False), 1, "the cancel's -ENOENT")
    assert_equal(p1.shared[].internal_completions, 1)
    assert_equal(p1.state[].internal_in_flight, 0)
    assert_true(not p1.state[].done, "the timer itself was never submitted")
    assert_equal(p1.live[], 1)
    assert_true(not p1.state[].request_reset(10), "a submitted cancel refuses resets")
    _del_fx(p1)

    var p2 = _new_fx()
    assert_true(p2.state[].request_reset(10))
    p2.state[].flush_deferred(driver)
    assert_true(not p2.state[].reset_requested)
    assert_equal(p2.state[].internal_in_flight, 1)
    assert_equal(driver.tick(wait=False), 1, "the update's -ENOENT")
    assert_equal(p2.shared[].internal_completions, 1)
    assert_equal(p2.state[].internal_in_flight, 0)
    assert_true(p2.state[].request_reset(20), "a completed update allows another")
    assert_true(p2.state[].request_cancel(), "and a cancel")
    _del_fx(p2)


def main() raises:
    test_cancel_orderings()
    print("ok: cancel orderings")
    test_update_orderings()
    print("ok: update orderings")
    test_two_updates_in_flight()
    print("ok: two updates in flight")
    test_update_then_cancel_in_flight()
    print("ok: update then cancel in flight")
    test_owner_dropped_before_and_after()
    print("ok: owner dropped before and after")
    test_request_dropped_by_expiry()
    print("ok: request dropped by expiry")
    test_reset_then_cancel_replaces_the_reset()
    print("ok: reset then cancel")
    test_refused_then_expiry_settles_once()
    print("ok: refused then expiry")
    test_full_queue_requeues_then_expiry()
    print("ok: full queue re-queues then expiry")
    test_other_refusal_drops_the_request()
    print("ok: other refusal drops the request")
    test_result_mapping()
    print("ok: result mapping")
    test_guards()
    print("ok: guards")
    test_notify_done_is_inert()
    print("ok: notify_done is inert")
    test_flush_submits_through_a_driver()
    print("ok: flush submits through a driver")
    print("PASS: test_timer_state.mojo")
