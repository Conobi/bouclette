"""IoUringDriver.tick(wait, timeout_ms): bounded waits return on time.

Three cases: an idle driver bounded at 50 ms returns 0 no earlier than
50 ms and well before 500 ms; a 0 ms bound polls; an unbounded wait
with a 10 ms timeout operation returns exactly that one completion.
The sentinel path (kernels without IORING_FEAT_EXT_ARG) runs through
the same assertions; the sentinel is never counted.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.drivers.io_uring import IoUringDriver
from boucle.proactor.completion import Completion
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


def test_idle_bounded_tick_returns_zero_on_time() raises:
    """`tick(wait=True, timeout_ms=50)` on an idle driver: 0 after 50..500 ms."""
    var driver = IoUringDriver(capacity=8)
    var t0 = perf_counter_ns()
    var n = driver.tick(True, 50)
    var elapsed_ms = (perf_counter_ns() - t0) // 1_000_000
    assert_equal(n, 0)
    assert_true(elapsed_ms >= 50, "returned early: " + String(elapsed_ms))
    assert_true(elapsed_ms < 500, "returned late: " + String(elapsed_ms))


def test_zero_bound_polls() raises:
    """`tick(wait=True, timeout_ms=0)` returns 0 without blocking."""
    var driver = IoUringDriver(capacity=8)
    var t0 = perf_counter_ns()
    var n = driver.tick(True, 0)
    var elapsed_ms = (perf_counter_ns() - t0) // 1_000_000
    assert_equal(n, 0)
    assert_true(elapsed_ms < 100, "poll blocked: " + String(elapsed_ms))


def test_unbounded_wait_counts_only_the_timer() raises:
    """A 10 ms timeout op is the one completion an unbounded tick returns."""
    var driver = IoUringDriver(capacity=8)
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
    var n = driver.tick(True, -1)
    assert_equal(n, 1)
    assert_true(slot.fired, "timer must have fired")
    assert_equal(slot.result, -Int(ETIME))
    _ = cmp
    _ = ts


def test_bounded_wait_longer_than_timer_counts_only_the_timer() raises:
    """A 10 ms timer under a 1000 ms bound returns 1 as soon as the timer fires."""
    var driver = IoUringDriver(capacity=8)
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
    var t0 = perf_counter_ns()
    var n = driver.tick(True, 1000)
    var elapsed_ms = (perf_counter_ns() - t0) // 1_000_000
    assert_equal(n, 1)
    assert_true(slot.fired, "timer must have fired")
    assert_true(elapsed_ms < 500, "waited for the bound, not the timer")
    _ = cmp
    _ = ts


def main() raises:
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_idle_bounded_tick_returns_zero_on_time()
    test_zero_bound_polls()
    test_unbounded_wait_counts_only_the_timer()
    test_bounded_wait_longer_than_timer_counts_only_the_timer()
    print("PASS: test_io_uring_tick_timeout.mojo")
