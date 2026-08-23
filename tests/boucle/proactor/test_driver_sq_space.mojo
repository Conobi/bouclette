"""Test IoDriver.sq_space() returns available slot count."""

from std.memory import Pointer
from std.testing import assert_true

from boucle.proactor.completion import Completion
from boucle.drivers.probe import ProbeCompletionDriver
from boucle.socle.linux.raw import __kernel_timespec


struct SpaceTracker:
    """Records callback invocations for sq_space test."""

    var fired: Bool

    def __init__(out self):
        """Construct an unfired tracker."""
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback that records the completion fired."""
        var self_ptr = Pointer[SpaceTracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].fired = True


def test_driver_sq_space() raises:
    """Verify that sq_space decreases after submission and recovers after tick."""
    var driver = ProbeCompletionDriver(sq_entries=16)

    # Fresh driver should have space.
    var space = driver.sq_space()
    assert_true(space > 0)

    # Use a timeout rather than a NOP because epoll's NOP bypasses the
    # internal pool (it's immediately ready). Timeout allocates a slot
    # on both io_uring and epoll backends.
    var ts = __kernel_timespec(tv_sec=Int64(5), tv_nsec=Int64(0))
    var ts_ptr = Pointer[NoneType, ImmStaticOrigin](
        unsafe_from_address=Int(Pointer(to=ts))
    )

    var timeout_tracker = SpaceTracker()
    var timeout_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=timeout_tracker))
    )
    var timeout_cmp = Completion(
        invoke=SpaceTracker.on_complete, context=timeout_ctx
    )
    var timeout_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=timeout_cmp))
    )

    var cancel_tracker = SpaceTracker()
    var cancel_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cancel_tracker))
    )
    var cancel_cmp = Completion(
        invoke=SpaceTracker.on_complete, context=cancel_ctx
    )
    var cancel_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cancel_cmp))
    )

    var space_before = driver.sq_space()
    driver.submit_timeout(ts_ptr, timeout_cmp_ptr)
    var space_after = driver.sq_space()
    assert_true(space_after < space_before)

    # Cancel the timeout and tick to drain. Space should recover.
    driver.submit_cancel(timeout_cmp_ptr, cancel_cmp_ptr)

    var ticks = 0
    while not timeout_tracker.fired or not cancel_tracker.fired:
        _ = driver.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for completions"

    var space_final = driver.sq_space()
    assert_true(space_final >= space_before)

    # Keep completions alive past callbacks.
    _ = timeout_cmp
    _ = cancel_cmp


def main() raises:
    test_driver_sq_space()
    print("PASS: test_driver_sq_space.mojo")
