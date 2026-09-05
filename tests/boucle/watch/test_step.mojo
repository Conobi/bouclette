"""WatchLoop.step(timeout_ms): one bounded tick, observable completions only.

Runs on Backend.AUTO and forced Backend.EPOLL. Covers: run() with
nothing pending returns at once; step(0) returns 0 with nothing pending;
step(50) with nothing pending returns 0 after at least 50 ms and before
500 ms; a 10 ms timer is exactly one observable completion; a long timer
left armed makes step(0) return 0 and stays in flight; the cancel a
connect_with_timeout submits internally is not counted.
"""

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.drivers.backend import Backend
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.watch import WatchLoop


def _elapsed_ms(start: Int) -> Int:
    """Milliseconds since `start` (a perf_counter_ns reading)."""
    return (perf_counter_ns() - start) // 1_000_000


def _check_run_with_nothing_pending(backend: Backend) raises:
    """run() with nothing submitted returns immediately."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var start = perf_counter_ns()
    loop.run()
    assert_true(_elapsed_ms(start) < 100, "run() blocked with nothing pending")


def _check_step_zero_with_nothing_pending(backend: Backend) raises:
    """step(0) returns 0 at once."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var start = perf_counter_ns()
    assert_equal(loop.step(0), 0)
    assert_true(_elapsed_ms(start) < 100, "step(0) blocked")


def _check_step_bounded_with_nothing_pending(backend: Backend) raises:
    """step(50) returns 0 after at least 50 ms and at most 500 ms."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var start = perf_counter_ns()
    assert_equal(loop.step(50), 0)
    var ms = _elapsed_ms(start)
    assert_true(ms >= 50, "step(50) returned early: " + String(ms))
    assert_true(ms <= 500, "step(50) returned late: " + String(ms))


def _check_step_delivers_one_timer(backend: Backend) raises:
    """A 10 ms timer is one observable completion of an unbounded step."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(10)
    assert_equal(loop.step(), 1)
    assert_true(timer.done(), "timer must be done after the step")
    assert_true(timer.result(), "timer must have expired")
    assert_equal(loop.in_flight_count(), 0)


def _check_step_zero_leaves_long_timer_armed(backend: Backend) raises:
    """step(0) with a 5 s timer armed returns 0 and keeps it in flight."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var timer = loop.timeout(5000)
    var start = perf_counter_ns()
    assert_equal(loop.step(0), 0)
    assert_true(_elapsed_ms(start) < 100, "step(0) waited for the timer")
    assert_equal(loop.in_flight_count(), 1)
    assert_true(not timer.done(), "timer must still be armed")
    _ = timer^


def _check_internal_cancel_not_counted(backend: Backend) raises:
    """connect_with_timeout to a closed port: three completions, two observable."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=UInt16(1))
    var future = loop.connect_with_timeout(client, target, 1000)
    var observed = 0
    var steps = 0
    while loop.in_flight_count() > 0:
        observed += loop.step()
        steps += 1
        if steps > 10:
            raise "composite did not settle in 10 steps"
    assert_equal(observed, 2, "connect result and cancelled timeout only")
    assert_equal(loop.pending_composites(), 0)
    assert_true(future.done(), "composite must be done")
    _ = future^
    client.close()


def _check_all(backend: Backend) raises:
    """Run every check on one backend."""
    _check_run_with_nothing_pending(backend)
    _check_step_zero_with_nothing_pending(backend)
    _check_step_bounded_with_nothing_pending(backend)
    _check_step_delivers_one_timer(backend)
    _check_step_zero_leaves_long_timer_armed(backend)
    _check_internal_cancel_not_counted(backend)


def main() raises:
    _check_all(Backend.AUTO)
    _check_all(Backend.EPOLL)
    print("PASS: test_step.mojo")
