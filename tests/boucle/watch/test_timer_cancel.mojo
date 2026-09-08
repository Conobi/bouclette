"""`TimerFuture.cancel()` on `WatchLoop`, on Backend.AUTO and Backend.EPOLL.

Covers: cancel before expiry (result False, run() returns at once, a
second cancel is refused), cancel after expiry (refused, result True),
cancel racing an expiry the loop has not reaped yet, cancel then drop
before run(), cancel after the loop is gone, `step()` reporting a
cancelled timer exactly once, and a stale timer key on the deferred
list being skipped rather than dereferenced.
"""

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns, sleep

from boucle.drivers.backend import Backend
from boucle.watch import WatchLoop
from boucle.watch._callback import _KIND_BITS


def _elapsed_ms(start: Int) -> Int:
    """Milliseconds since `start` (a perf_counter_ns reading)."""
    return (perf_counter_ns() - start) // 1_000_000


def _check_cancel_before_expiry(backend: Backend) raises:
    """A 5 s timer cancelled before run(): result False, run() returns at once."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    assert_true(timer.cancel(), "first cancel is accepted")
    assert_true(not timer.cancel(), "second cancel is refused")
    assert_equal(loop.pending_composites(), 1, "the key is queued once")
    var start = perf_counter_ns()
    loop.run()
    assert_true(_elapsed_ms(start) < 1000, "run() waited for the 5 s deadline")
    assert_true(timer.done())
    assert_true(not timer.result(), "a cancelled timer reports False")
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)
    assert_equal(loop.pending_composites(), 0)


def _check_cancel_after_expiry(backend: Backend) raises:
    """A timer that already expired refuses cancel and reset; result stays True."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(1)
    loop.run()
    assert_true(timer.done())
    assert_true(not timer.cancel())
    assert_true(not timer.reset(10))
    assert_true(timer.result())
    assert_equal(loop.in_flight_count(), 0)


def _check_cancel_races_expiry(backend: Backend) raises:
    """A 3 ms timer handed to the kernel, cancelled 10 ms later, then run().

    On io_uring the hrtimer has fired: the cancel answers -ENOENT and
    the timer's -ETIME is reaped in the same tick, so `result()` is
    True. The epoll driver counts a deadline as expired only once a
    tick popped it, so the flushed cancel still finds the timer and
    `result()` is False. Both end clean.
    """
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(3)
    assert_equal(loop.step(0), 0, "submit to the kernel without reaping")
    sleep(0.01)
    assert_true(timer.cancel(), "the loop has not seen the expiry yet")
    loop.run()
    assert_true(timer.done())
    var expired = timer.result()
    if loop.backend() is Backend.IO_URING:
        assert_true(expired, "io_uring: the expiry won the race")
    else:
        assert_true(not expired, "epoll: the cancel found the timer in the heap")
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)


def _check_cancel_then_drop_before_run(backend: Backend) raises:
    """Cancel then drop the handle: the cancel is still flushed and the slot settles."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    assert_true(timer.cancel())
    _ = timer^
    var start = perf_counter_ns()
    loop.run()
    assert_true(_elapsed_ms(start) < 1000, "run() waited for the 5 s deadline")
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)
    assert_equal(loop._timers.active(), 0, "slot settled after both completions")


def _check_cancel_after_loop_gone(backend: Backend) raises:
    """Once the loop is destroyed, cancel and reset return False and result() reports the loss."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(10_000)
    _ = loop^
    assert_true(not timer.cancel())
    assert_true(not timer.reset(10))
    var caught = False
    try:
        _ = timer.result()
    except e:
        caught = "loop destroyed" in String(e)
    assert_true(caught, "result() reports the destroyed loop")
    _ = timer^


def _check_step_counts_cancelled_timer_once(backend: Backend) raises:
    """The cancelled timer's -ECANCELED is the only observable completion."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    assert_true(timer.cancel())
    var observed = 0
    var steps = 0
    var start = perf_counter_ns()
    while not timer.done():
        observed += loop.step(100)
        steps += 1
        if steps > 20:
            raise "cancelled timer did not complete in 20 steps"
    assert_true(_elapsed_ms(start) < 2000, "the cancel did not take effect")
    assert_equal(observed, 1, "cancel's own completion must not be reported")
    assert_true(not timer.result())
    assert_equal(loop._pending, 0)
    assert_equal(loop.in_flight_count(), 0)


def _check_stale_timer_key_is_skipped(backend: Backend) raises:
    """A settled timer's key left on the deferred list is dropped, not dereferenced."""
    var loop = WatchLoop(capacity=4, backend=backend)
    var timer = loop.timeout(1)
    var key = timer._state[]._link.key
    loop.run()
    assert_true(timer.result())
    _ = timer^
    _ = loop.step(0)  # the sweep releases the orphaned slot
    assert_equal(loop._timers.active(), 0)
    var index = key >> _KIND_BITS

    # Poison the freed slot so that an unguarded flush would submit a
    # cancel and mark it submitted.
    var slot = loop._timers._slot(index)
    slot[].cancel_requested = True
    slot[].cancel_submitted = False
    slot[].done = False
    loop._deferred[].append(key)
    assert_equal(loop.pending_composites(), 1)

    assert_equal(loop.step(0), 0, "nothing observable happens")
    assert_equal(loop.pending_composites(), 0, "the stale key is dropped")
    assert_true(not slot[].cancel_submitted, "the stale key must not reach the state")
    assert_equal(loop._pending, 0)
    assert_equal(loop._timers.active(), 0)
    assert_equal(loop.in_flight_count(), 0)
    _ = loop^


def _check_all(backend: Backend) raises:
    """Run every check on one backend."""
    _check_cancel_before_expiry(backend)
    _check_cancel_after_expiry(backend)
    _check_cancel_races_expiry(backend)
    _check_cancel_then_drop_before_run(backend)
    _check_cancel_after_loop_gone(backend)
    _check_step_counts_cancelled_timer_once(backend)
    _check_stale_timer_key_is_skipped(backend)


def main() raises:
    _check_all(Backend.AUTO)
    print("ok: AUTO")
    _check_all(Backend.EPOLL)
    print("ok: EPOLL")
    print("PASS: test_timer_cancel.mojo")
