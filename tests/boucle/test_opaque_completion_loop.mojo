"""Test the opaque CompletionLoop (no generic parameter).

Verifies that CompletionLoop can be constructed, submit a NOP with
a Completion callback, and dispatch the callback via tick().
"""

from std.memory import Pointer
from std.testing import assert_equal

from boucle.completion import CompletionLoop, Completion


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


def test_nop_single() raises:
    """Submit a single NOP and verify the callback fires."""
    var loop = CompletionLoop(sq_entries=16)
    var tracker = Tracker()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var cmp = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    loop.nop(cmp_ptr)
    _ = loop.tick(wait=True)

    assert_equal(tracker.count, 1)
    assert_equal(Int(tracker.last_result), 0)
    _ = cmp


def test_nop_multiple() raises:
    """Submit three NOPs and verify all callbacks fire."""
    var loop = CompletionLoop(sq_entries=16)
    var tracker = Tracker()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )

    var cmp1 = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp2 = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp3 = Completion(invoke=Tracker.on_complete, context=ctx)

    var p1 = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp1))
    )
    var p2 = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp2))
    )
    var p3 = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp3))
    )

    loop.nop(p1)
    loop.nop(p2)
    loop.nop(p3)
    _ = loop.tick(wait=True)

    assert_equal(tracker.count, 3)
    _ = cmp1
    _ = cmp2
    _ = cmp3


def test_run_once() raises:
    """Verify run_once() blocks until a completion fires."""
    var loop = CompletionLoop(sq_entries=16)
    var tracker = Tracker()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var cmp = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    loop.nop(cmp_ptr)
    loop.run_once()

    assert_equal(tracker.count, 1)
    _ = cmp


def main() raises:
    test_nop_single()
    test_nop_multiple()
    test_run_once()
    print("PASS: test_opaque_completion_loop")
