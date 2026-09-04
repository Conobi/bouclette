"""Integration test: EventLoop wrapping completion driver dispatches NOP."""

from std.memory import Pointer
from std.testing import assert_equal

from boucle.proactor.completion import Completion
from boucle.proactor.loop import EventLoop
from boucle.drivers.auto import AutoDriver


struct Tracker:
    """Records callback invocations for test assertions."""

    var last_result: Int
    var last_flags: UInt32
    var count: Int

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.last_result = 0
        self.last_flags = UInt32(0)
        self.count = 0

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records result into the Tracker."""
        var self_ptr = Pointer[Tracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].last_result = result
        self_ptr[].last_flags = flags
        self_ptr[].count += 1


def test_event_loop() raises:
    """Wrap completion driver in EventLoop, submit NOP, and run_once."""
    var driver = AutoDriver(sq_entries=16)
    var loop = EventLoop(driver^)

    var tracker = Tracker()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var cmp = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    loop.driver.nop(cmp_ptr)
    loop.run_once()

    assert_equal(tracker.count, 1)
    assert_equal(Int(tracker.last_result), 0)
    _ = cmp


def main() raises:
    test_event_loop()
    print("PASS: test_event_loop.mojo")
