"""Integration test: EventLoop wrapping IoUringDriver dispatches NOP."""

from std.memory import UnsafePointer
from std.testing import assert_equal

from boucle.proactor.completion import Completion
from boucle.proactor.loop import EventLoop
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


def main() raises:
    """Wrap IoUringDriver in EventLoop, submit NOP, and run_once."""
    var driver = IoUringDriver(sq_entries=16)
    var loop = EventLoop(driver^)

    var tracker = Tracker()
    var ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=tracker))
    )
    var cmp = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=cmp))
    )

    loop.driver.submit_nop(cmp_ptr)
    loop.run_once()

    assert_equal(tracker.count, 1)
    assert_equal(Int(tracker.last_result), 0)

    print("PASS: test_event_loop")
