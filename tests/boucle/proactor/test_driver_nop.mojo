"""Integration test: submit NOP via IoUringDriver and verify callback fires."""

from std.memory import UnsafePointer
from std.testing import assert_equal

from boucle.proactor.completion import Completion
from boucle.drivers.io_uring import IoUringDriver


struct Tracker:
    """Records callback invocations for test assertions."""

    var last_result: Int32
    var last_flags: UInt32
    var count: Int

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.last_result = Int32(0)
        self.last_flags = UInt32(0)
        self.count = 0

    @staticmethod
    def on_complete(
        ctx: UnsafePointer[NoneType, MutAnyOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback that records result into the Tracker."""
        var self_ptr = UnsafePointer[Tracker, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].last_result = result
        self_ptr[].last_flags = flags
        self_ptr[].count += 1


def test_driver_nop() raises:
    """Submit a NOP through IoUringDriver, tick, and verify dispatch."""
    var driver = IoUringDriver(sq_entries=16)
    var tracker = Tracker()
    var ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=tracker))
    )
    var cmp = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=cmp))
    )

    driver.submit_nop(cmp_ptr)
    driver.tick(wait=True)

    assert_equal(tracker.count, 1)
    assert_equal(Int(tracker.last_result), 0)


def main() raises:
    test_driver_nop()
    print("PASS: test_driver_nop.mojo")
