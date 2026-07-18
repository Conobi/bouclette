"""Test Completion struct dispatch."""

from std.memory import UnsafePointer
from std.testing import assert_equal
from boucle.proactor.completion import Completion


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
    """Exercise Completion fire dispatch."""
    var tracker = Tracker()
    var ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=tracker))
    )
    var cmp = Completion(invoke=Tracker.on_complete, context=ctx)

    # Fire with known values.
    cmp.fire(result=Int32(42), flags=UInt32(7))

    assert_equal(tracker.count, 1)
    assert_equal(Int(tracker.last_result), 42)
    assert_equal(Int(tracker.last_flags), 7)

    # Fire again with different values.
    cmp.fire(result=Int32(-111), flags=UInt32(0))
    assert_equal(tracker.count, 2)
    assert_equal(Int(tracker.last_result), -111)

    print("PASS: test_completion")
