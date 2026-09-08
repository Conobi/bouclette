"""`TimerFuture.reset()` on `WatchLoop`, on Backend.AUTO and Backend.EPOLL.

Covers: a reset that extends a 10 ms timer to 500 ms, one that shortens
a 5 s timer to 10 ms, two resets before a flush collapsing to the last
value, reset then cancel, reset refused after expiry, reset then drop
before run(), a reset driven by `step()`, the Int32.MAX bound on
`reset` and `timeout`, and a 100-iteration re-arm loop that ends with
one observable completion.
"""

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.drivers.backend import Backend
from boucle.watch import WatchLoop


def _elapsed_ms(start: Int) -> Int:
    """Milliseconds since `start` (a perf_counter_ns reading)."""
    return (perf_counter_ns() - start) // 1_000_000


def _check_reset_extends(backend: Backend) raises:
    """A 10 ms timer reset to 500 ms before run() fires after at least 400 ms."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(10)
    assert_true(timer.reset(500))
    var start = perf_counter_ns()
    loop.run()
    var ms = _elapsed_ms(start)
    assert_true(ms >= 400, "reset did not extend the timer: " + String(ms))
    assert_true(timer.result())
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)


def _check_reset_shortens(backend: Backend) raises:
    """A 5 s timer reset to 10 ms fires under 1 s."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    assert_true(timer.reset(10))
    var start = perf_counter_ns()
    loop.run()
    assert_true(_elapsed_ms(start) < 1000, "reset did not shorten the timer")
    assert_true(timer.result())
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)


def _check_reset_twice_last_wins(backend: Backend) raises:
    """Two resets before the flush: one key queued, the last value applies."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    assert_true(timer.reset(5000))
    assert_true(timer.reset(10))
    assert_equal(loop.pending_composites(), 1, "collapsed to one queued key")
    var start = perf_counter_ns()
    loop.run()
    assert_true(_elapsed_ms(start) < 1000, "the last reset did not win")
    assert_true(timer.result())
    assert_equal(loop.in_flight_count(), 0)


def _check_reset_then_cancel(backend: Backend) raises:
    """A cancel after a reset drops the reset; the timer reports False under 1 s."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    assert_true(timer.reset(10))
    assert_true(timer.cancel())
    assert_true(not timer._state[].reset_requested, "the reset was replaced")
    var start = perf_counter_ns()
    loop.run()
    assert_true(_elapsed_ms(start) < 1000)
    assert_true(not timer.result(), "cancelled, not expired")
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)


def _check_reset_after_expiry_returns_false(backend: Backend) raises:
    """A reset on an expired timer is refused; result() stays True."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(1)
    loop.run()
    assert_true(not timer.reset(10))
    assert_true(timer.result())


def _check_reset_then_drop_before_run(backend: Backend) raises:
    """Reset then drop: the update is still flushed and the timer fires at the new deadline."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    assert_true(timer.reset(10))
    _ = timer^
    var start = perf_counter_ns()
    loop.run()
    assert_true(_elapsed_ms(start) < 1000, "the dropped handle's reset was lost")
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)
    assert_equal(loop._timers.active(), 0, "slot settled after both completions")


def _check_step_after_reset(backend: Backend) raises:
    """`step(100)` after `reset(10)` on a 5 s timer: done under 1 s, one observable, True."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    assert_true(timer.reset(10))
    var observed = 0
    var steps = 0
    var start = perf_counter_ns()
    while not timer.done():
        observed += loop.step(100)
        steps += 1
        if steps > 20:
            raise "reset timer did not fire in 20 steps"
    assert_true(_elapsed_ms(start) < 1000, "the reset did not take effect")
    assert_equal(observed, 1, "the update's completion must not be reported")
    assert_true(timer.result())
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)


def _check_bound(backend: Backend) raises:
    """`reset` above Int32.MAX ms is refused; `timeout` above it raises EINVAL."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    assert_true(not timer.reset(UInt64(Int32.MAX) + 1))
    assert_equal(loop.pending_composites(), 0, "nothing queued")
    var raised = False
    try:
        var too_long = loop.timeout(UInt64(Int32.MAX) + 1)
        _ = too_long^
    except:
        raised = True
    assert_true(raised, "timeout above the bound must raise")
    assert_equal(loop.in_flight_count(), 1, "only the first timer is tracked")
    assert_true(timer.cancel(), "the timer is still cancellable")
    loop.run()
    assert_true(not timer.result())
    assert_equal(loop.in_flight_count(), 0)


def _check_rearm_loop(backend: Backend) raises:
    """100 x (reset(5) + step(0)) keeps the timer armed; then it fires exactly once."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    var observed = 0
    for i in range(100):
        assert_true(timer.reset(5), "reset " + String(i) + " must be accepted")
        observed += loop.step(0)
    assert_equal(observed, 0, "no observable completion while re-arming")
    var steps = 0
    while not timer.done():
        observed += loop.step(100)
        steps += 1
        if steps > 20:
            raise "re-armed timer did not fire in 20 steps"
    assert_equal(observed, 1, "one observable completion over the whole test")
    assert_true(timer.result())
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)
    assert_equal(loop.pending_composites(), 0)


def _check_all(backend: Backend) raises:
    """Run every check on one backend."""
    _check_reset_extends(backend)
    _check_reset_shortens(backend)
    _check_reset_twice_last_wins(backend)
    _check_reset_then_cancel(backend)
    _check_reset_after_expiry_returns_false(backend)
    _check_reset_then_drop_before_run(backend)
    _check_step_after_reset(backend)
    _check_bound(backend)
    _check_rearm_loop(backend)


def main() raises:
    _check_all(Backend.AUTO)
    print("ok: AUTO")
    _check_all(Backend.EPOLL)
    print("ok: EPOLL")
    print("PASS: test_timer_reset.mojo")
