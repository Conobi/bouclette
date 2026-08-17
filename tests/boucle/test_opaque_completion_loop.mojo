"""Test the opaque CompletionLoop (no generic parameter).

Verifies that CompletionLoop can be constructed, submit a NOP with
a Completion callback, and dispatch the callback via tick().
"""

from std.memory import UnsafePointer
from std.testing import assert_equal

from boucle.completion import CompletionLoop, Completion


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


def test_nop_single() raises:
    """Submit a single NOP and verify the callback fires."""
    var loop = CompletionLoop(sq_entries=16)
    var tracker = Tracker()
    var ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=tracker))
    )
    var cmp = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=cmp))
    )

    loop.submit_nop(cmp_ptr)
    loop.tick(wait=True)

    assert_equal(tracker.count, 1)
    assert_equal(Int(tracker.last_result), 0)


def test_nop_multiple() raises:
    """Submit three NOPs and verify all callbacks fire."""
    var loop = CompletionLoop(sq_entries=16)
    var tracker = Tracker()
    var ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=tracker))
    )

    var cmp1 = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp2 = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp3 = Completion(invoke=Tracker.on_complete, context=ctx)

    var p1 = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=cmp1))
    )
    var p2 = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=cmp2))
    )
    var p3 = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=cmp3))
    )

    loop.submit_nop(p1)
    loop.submit_nop(p2)
    loop.submit_nop(p3)
    loop.tick(wait=True)

    assert_equal(tracker.count, 3)


def test_run_once() raises:
    """Verify run_once() blocks until a completion fires."""
    var loop = CompletionLoop(sq_entries=16)
    var tracker = Tracker()
    var ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=tracker))
    )
    var cmp = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=cmp))
    )

    loop.submit_nop(cmp_ptr)
    loop.run_once()

    assert_equal(tracker.count, 1)


def main() raises:
    test_nop_single()
    test_nop_multiple()
    test_run_once()
    print("PASS: test_opaque_completion_loop")
