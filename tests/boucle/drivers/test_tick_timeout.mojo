"""`tick(wait, timeout_ms)` on epoll, AutoDriver and CompletionLoop.

The epoll driver folds the caller's bound into its epoll_wait timeout:
the result is the smaller of the bound and the time to the earliest
timer. The pure helper is tested first, then the live drivers.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.drivers.auto import AutoDriver
from boucle.drivers.backend import Backend
from boucle.drivers.epoll_completion import (
    EpollCompletionDriver,
    _epoll_wait_timeout_ms,
)
from boucle.drivers.io_uring import IoUringDriver
from boucle.proactor.completion import Completion
from boucle.proactor.completion_loop import CompletionLoop
from boucle.socle.linux.raw import ETIME, __kernel_timespec


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var d = IoUringDriver(capacity=4)
        _ = d^
        return True
    except:
        return False


struct Slot:
    """Records one completion."""

    var result: Int
    var fired: Bool

    def __init__(out self):
        """Construct an unfired slot."""
        self.result = 0
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Record the result."""
        var self_ptr = Pointer[Slot, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


def test_helper_bound_without_deadline() raises:
    """No timer armed: the bound is the timeout; -1 stays -1."""
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=True, has_deadline=False, remaining_ns=0, timeout_ms=50
        ),
        Int32(50),
    )
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=True, has_deadline=False, remaining_ns=0, timeout_ms=0
        ),
        Int32(0),
    )
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=True, has_deadline=False, remaining_ns=0, timeout_ms=-1
        ),
        Int32(-1),
    )


def test_helper_bound_and_deadline_take_the_smaller() raises:
    """The earlier of bound and deadline wins."""
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=True,
            has_deadline=True,
            remaining_ns=5_000_000_000,
            timeout_ms=50,
        ),
        Int32(50),
    )
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=True,
            has_deadline=True,
            remaining_ns=10_000_000,
            timeout_ms=50,
        ),
        Int32(10),
    )
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=True, has_deadline=True, remaining_ns=-5, timeout_ms=50
        ),
        Int32(0),
    )


def test_helper_not_waiting_ignores_bound() raises:
    """`wait=False` is always 0, whatever the bound."""
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=False, has_deadline=False, remaining_ns=0, timeout_ms=50
        ),
        Int32(0),
    )


def test_helper_huge_bound_clamps() raises:
    """A bound past Int32.MAX milliseconds clamps instead of wrapping."""
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=True,
            has_deadline=False,
            remaining_ns=0,
            timeout_ms=Int(Int32.MAX) + 1000,
        ),
        Int32.MAX,
    )


def test_helper_default_is_unbounded() raises:
    """Omitting the bound keeps the old behaviour."""
    assert_equal(
        _epoll_wait_timeout_ms(wait=True, has_deadline=False, remaining_ns=0),
        Int32(-1),
    )


def test_epoll_idle_bounded_tick() raises:
    """`tick(wait=True, timeout_ms=50)` on an idle epoll driver: 0 after 50..500 ms."""
    var driver = EpollCompletionDriver(capacity=8)
    var start = perf_counter_ns()
    var n = driver.tick(True, 50)
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    assert_equal(n, 0)
    assert_true(elapsed_ms >= 50, "returned early: " + String(elapsed_ms))
    assert_true(elapsed_ms < 500, "returned late: " + String(elapsed_ms))


def test_epoll_timer_under_bound() raises:
    """A 10 ms timer under a 1000 ms bound fires and is the one completion."""
    var driver = EpollCompletionDriver(capacity=8)
    var slot = Slot()
    var cmp = Completion(
        invoke=Slot.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=slot))
        ),
    )
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )
    var ts = __kernel_timespec(tv_sec=Int64(0), tv_nsec=Int64(10_000_000))
    var ts_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=ts))
    )
    driver.timeout(ts_ptr, cmp_ptr)
    var start = perf_counter_ns()
    var n = driver.tick(True, 1000)
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    assert_equal(n, 1)
    assert_true(slot.fired, "timer must have fired")
    assert_equal(slot.result, -Int(ETIME))
    assert_true(elapsed_ms < 500, "waited for the bound, not the timer")
    _ = cmp
    _ = ts


def test_auto_and_completion_loop_pass_the_bound() raises:
    """AutoDriver and CompletionLoop accept the bound and poll at 0."""
    var auto = AutoDriver(capacity=8, backend=Backend.EPOLL)
    var start = perf_counter_ns()
    assert_equal(auto.tick(True, 0), 0)
    assert_equal(auto.tick(wait=False), 0)
    var cl = CompletionLoop(capacity=8, backend=Backend.EPOLL)
    assert_equal(cl.tick(True, 0), 0)
    assert_equal(cl.tick(wait=False), 0)
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    assert_true(elapsed_ms < 100, "polls blocked: " + String(elapsed_ms))
    var start2 = perf_counter_ns()
    assert_equal(cl.tick(True, 30), 0)
    var waited_ms = (perf_counter_ns() - start2) // 1_000_000
    assert_true(waited_ms >= 30, "returned early: " + String(waited_ms))
    assert_true(waited_ms < 500, "returned late: " + String(waited_ms))


def test_auto_forced_io_uring_forwards_bound() raises:
    """AutoDriver forwards a 50 ms bound to the io_uring driver it wraps."""
    if not _has_io_uring():
        print("  SKIP: io_uring not available")
        return
    var auto = AutoDriver(capacity=8, backend=Backend.IO_URING)
    var start = perf_counter_ns()
    var n = auto.tick(True, 50)
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    assert_equal(n, 0)
    assert_true(elapsed_ms >= 50, "returned early: " + String(elapsed_ms))
    assert_true(elapsed_ms < 500, "returned late: " + String(elapsed_ms))


def main() raises:
    test_helper_bound_without_deadline()
    test_helper_bound_and_deadline_take_the_smaller()
    test_helper_not_waiting_ignores_bound()
    test_helper_huge_bound_clamps()
    test_helper_default_is_unbounded()
    test_epoll_idle_bounded_tick()
    test_epoll_timer_under_bound()
    test_auto_and_completion_loop_pass_the_bound()
    test_auto_forced_io_uring_forwards_bound()
    print("PASS: test_tick_timeout.mojo")
