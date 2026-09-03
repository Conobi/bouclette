"""Integration test: submit timeout + cancel via completion driver."""

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.proactor.completion import Completion
from boucle.drivers.probe import ProbeCompletionDriver
from boucle.socle.linux.raw import __kernel_timespec


struct TimeoutTracker:
    """Records callback invocations for timeout and cancel completions."""

    var timeout_result: Int32
    var timeout_flags: UInt32
    var timeout_fired: Bool
    var cancel_result: Int32
    var cancel_flags: UInt32
    var cancel_fired: Bool

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.timeout_result = Int32(0)
        self.timeout_flags = UInt32(0)
        self.timeout_fired = False
        self.cancel_result = Int32(0)
        self.cancel_flags = UInt32(0)
        self.cancel_fired = False

    @staticmethod
    def on_timeout(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback for the timeout completion."""
        var self_ptr = Pointer[TimeoutTracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].timeout_result = result
        self_ptr[].timeout_flags = flags
        self_ptr[].timeout_fired = True

    @staticmethod
    def on_cancel(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback for the cancel completion."""
        var self_ptr = Pointer[TimeoutTracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].cancel_result = result
        self_ptr[].cancel_flags = flags
        self_ptr[].cancel_fired = True


def test_driver_timeout() raises:
    """Submit a 5s timeout, cancel it immediately, verify both CQEs."""
    var driver = ProbeCompletionDriver(sq_entries=16)
    var tracker = TimeoutTracker()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )

    # Wire timeout completion.
    var timeout_cmp = Completion(
        invoke=TimeoutTracker.on_timeout, context=ctx
    )
    var timeout_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=timeout_cmp))
    )

    # Wire cancel completion.
    var cancel_cmp = Completion(
        invoke=TimeoutTracker.on_cancel, context=ctx
    )
    var cancel_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cancel_cmp))
    )

    # Submit a 5-second timeout (long enough it won't fire naturally).
    var ts = __kernel_timespec(tv_sec=Int64(5), tv_nsec=Int64(0))
    var ts_ptr = Pointer[NoneType, ImmStaticOrigin](
        unsafe_from_address=Int(Pointer(to=ts))
    )
    driver.submit_timeout(ts_ptr, timeout_cmp_ptr)

    # Immediately submit a cancel targeting the timeout's completion.
    driver.submit_cancel(timeout_cmp_ptr, cancel_cmp_ptr)

    # Poll until both completions have fired.
    var ticks = 0
    while not (tracker.timeout_fired and tracker.cancel_fired):
        _ = driver.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for completions"

    # Timeout should report -ECANCELED (-125).
    assert_equal(
        Int(tracker.timeout_result),
        -125,
    )

    # Cancel itself should succeed (result == 0).
    assert_equal(
        Int(tracker.cancel_result),
        0,
    )
    _ = timeout_cmp
    _ = cancel_cmp
    _ = ts


def main() raises:
    test_driver_timeout()
    print("PASS: test_driver_timeout.mojo")
