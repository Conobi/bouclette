"""The per-kind slab behind WatchLoop: stable slots, reuse, and settle by key.

Two layers are exercised. `_Slab` is driven directly with a timer state
and a hand-made settle queue, so growth across chunks, pointer stability,
the one-push-per-slot rule and LIFO reuse can be checked without a
kernel. Then `WatchLoop` is driven with a tiny capacity so the same
properties hold end to end: operations beyond one chunk complete, slots
come back once a handle lets go, and a future outliving its loop still
reports the loss without touching freed memory.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.timeout import Timeout
from boucle.watch import WatchLoop, TimerFuture
from boucle.watch._callback import _KIND_BITS
from boucle.watch._slab import _Slab
from boucle.watch.timer import _TimerFutureState


def _queue_ptr(ref queue: List[Int]) -> Pointer[List[Int], MutUntrackedOrigin]:
    """Return an untracked pointer to a settle queue owned by the caller.

    Args:
        queue: The list standing in for the loop's settle queue.
    """
    return Pointer[List[Int], MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=queue))
    )


def test_slab_grows_in_chunks_and_keeps_addresses() raises:
    """Five states in chunks of two span three chunks and never move."""
    var queue = List[Int]()
    var slab = _Slab[_TimerFutureState](2, 5, _queue_ptr(queue))
    var ptrs = List[Pointer[_TimerFutureState, MutUntrackedOrigin]]()
    for _ in range(5):
        ptrs.append(slab.alloc(_TimerFutureState(Timeout.from_ms(1))))
    assert_equal(len(slab._chunks), 3, "five slots in chunks of two")
    assert_equal(slab.in_flight(), 5)
    # Growth after the fact must not move what was handed out.
    var addr0 = Int(ptrs[0])
    for _ in range(4):
        ptrs.append(slab.alloc(_TimerFutureState(Timeout.from_ms(1))))
    assert_equal(Int(ptrs[0]), addr0, "chunk growth must not move slots")
    assert_equal(slab.in_flight(), 9)
    for p in ptrs:
        p[].mark_owner_dropped()
    slab.detach_all()
    assert_equal(slab.in_flight(), 0)
    assert_true(not slab._leaked, "no handle was left attached")


def test_slot_is_queued_once_by_the_second_event() raises:
    """Completion then drop, or drop then completion, both push one key."""
    var queue = List[Int]()
    var slab = _Slab[_TimerFutureState](4, 5, _queue_ptr(queue))

    # Completion first: the live count drops, nothing is queued yet.
    var a = slab.alloc(_TimerFutureState(Timeout.from_ms(1)))
    a[].set_result(-62)
    a[].notify_done()
    assert_equal(slab.in_flight(), 0, "done leaves the live count")
    assert_equal(len(queue), 0, "handle still alive: nothing to settle")
    a[].mark_owner_dropped()
    assert_equal(len(queue), 1, "the drop is the second event")

    # Drop first: nothing is queued until the completion lands.
    var b = slab.alloc(_TimerFutureState(Timeout.from_ms(1)))
    b[].mark_owner_dropped()
    assert_equal(len(queue), 1, "dropped before done: not yet settleable")
    b[].set_result(-62)
    b[].notify_done()
    assert_equal(len(queue), 2, "the completion is the second event")

    # Keys route back to this slab and decode to the two slots.
    for key in queue:
        assert_equal(key & ((1 << _KIND_BITS) - 1), 5, "kind tag")
        slab.settle(key >> _KIND_BITS)
    assert_equal(len(slab._free), 4, "both slots are back on the free list")

    # A settled key seen twice is harmless.
    slab.settle(queue[0] >> _KIND_BITS)
    assert_equal(len(slab._free), 4)


def test_freed_slot_is_reused_before_growing() raises:
    """Releasing a slot and allocating again reuses it; no new chunk."""
    var queue = List[Int]()
    var slab = _Slab[_TimerFutureState](2, 5, _queue_ptr(queue))
    var a = slab.alloc(_TimerFutureState(Timeout.from_ms(1)))
    var b = slab.alloc(_TimerFutureState(Timeout.from_ms(1)))
    var addr_b = Int(b)
    b[].mark_owner_dropped()
    b[].set_result(-62)
    b[].notify_done()
    slab.settle(queue.pop() >> _KIND_BITS)
    var c = slab.alloc(_TimerFutureState(Timeout.from_ms(1)))
    assert_equal(Int(c), addr_b, "the released slot is handed out again")
    assert_equal(len(slab._chunks), 1, "no growth while a slot is free")
    a[].mark_owner_dropped()
    c[].mark_owner_dropped()
    slab.detach_all()


def test_detach_marks_live_handles_and_keeps_chunks() raises:
    """A state whose handle is alive at detach is marked loop_gone."""
    var queue = List[Int]()
    var slab = _Slab[_TimerFutureState](2, 5, _queue_ptr(queue))
    var held = slab.alloc(_TimerFutureState(Timeout.from_ms(1)))
    var orphan = slab.alloc(_TimerFutureState(Timeout.from_ms(1)))
    orphan[].mark_owner_dropped()
    slab.detach_all()
    assert_true(held[].loop_gone(), "live handle learns the loop is gone")
    assert_true(slab._leaked, "chunks stay allocated for that handle")
    assert_equal(len(slab._free), 1, "the orphan was released")
    held.unsafe_deinit_pointee()  # what the handle's drop would do


def test_loop_completes_more_operations_than_one_chunk() raises:
    """Nine timers on a capacity-two loop all expire and free their slots."""
    var loop = WatchLoop(capacity=2)
    var timers = List[TimerFuture]()
    for _ in range(9):
        timers.append(loop.timeout(1))
    assert_equal(loop.in_flight_count(), 9)
    loop.run()
    assert_equal(loop.in_flight_count(), 0)
    for i in range(9):
        assert_true(timers[i].result(), "every timer expired")
    assert_equal(len(loop._timers._chunks), 5, "nine slots in chunks of two")
    _ = timers^  # drop all handles: keys are queued
    _ = loop.timeout(1)
    loop.run()  # the sweep after this tick releases the nine slots
    assert_equal(len(loop._timers._free), 10, "all slots are free again")


def test_loop_reuses_slots_across_rounds() raises:
    """Repeated rounds settle into a bounded number of chunks.

    A handle dropped after `run()` returns is released by the sweep of
    the *next* run, so a round that drops after running needs a second
    chunk once, and never a third. A round that drops before running
    is released in the same run and never needs more than one.
    """
    var loop = WatchLoop(capacity=4)
    for _ in range(5):
        var round = List[TimerFuture]()
        for _ in range(4):
            round.append(loop.timeout(1))
        loop.run()
        _ = round^  # dropped after run(): released at the next sweep
    assert_equal(len(loop._timers._chunks), 2, "one chunk of lag, then steady")

    var early = WatchLoop(capacity=4)
    for _ in range(5):
        var round = List[TimerFuture]()
        for _ in range(4):
            round.append(early.timeout(1))
        _ = round^  # dropped before run(): released in the same run
        early.run()
    assert_equal(len(early._timers._chunks), 1, "no lag, one chunk")


def test_future_outliving_a_tiny_loop_reports_loop_gone() raises:
    """The leak-on-loop-gone path holds when the slot sits in a chunk."""
    var loop = WatchLoop(capacity=1)
    var t = loop.timeout(10_000)
    _ = loop^
    assert_true(not t.done())
    var caught = False
    try:
        _ = t.result()
    except e:
        caught = "loop destroyed" in String(e)
    assert_true(caught, "result() reports the destroyed loop")
    _ = t^


def test_key_has_room_for_ten_kinds() raises:
    """Kinds 0..9 (accept .. pool) fit in the low bits of a slot key."""
    assert_equal(_KIND_BITS, 4)
    var queue = List[Int]()
    var slab = _Slab[_TimerFutureState](2, 9, _queue_ptr(queue))
    var s = slab.alloc(_TimerFutureState(Timeout.from_ms(1)))
    s[].set_result(-62)
    s[].notify_done()
    s[].mark_owner_dropped()
    assert_equal(len(queue), 1)
    assert_equal(queue[0] & ((1 << _KIND_BITS) - 1), 9, "kind 9 survives the encoding")
    assert_equal(queue[0] >> _KIND_BITS, 0, "index 0 decodes back")
    slab.settle(queue[0] >> _KIND_BITS)
    assert_equal(len(slab._free), 2)


def test_active_count_and_rearmed_link() raises:
    """`active()` counts occupied slots; `rearmed()` re-counts a state as live."""
    var queue = List[Int]()
    var slab = _Slab[_TimerFutureState](4, 5, _queue_ptr(queue))
    assert_equal(slab.active(), 0)
    assert_true(not slab.is_active(0), "no slot before the first alloc")
    var p = slab.alloc(_TimerFutureState(Timeout.from_ms(1)))
    assert_equal(slab.active(), 1)
    assert_true(slab.is_active(0), "slot 0 holds the state")
    assert_equal(slab.in_flight(), 1)

    # A completion decrements live; a re-arm counts it live again.
    p[]._link.completed(False)
    assert_equal(slab.in_flight(), 0)
    p[]._link.rearmed()
    assert_equal(slab.in_flight(), 1)
    p[]._link.completed(True)
    assert_equal(slab.in_flight(), 0)
    assert_equal(len(queue), 1, "the second event queues the key once")

    # settle() debug_asserts owner_dropped(), so the real method is called
    # here too, even though `done` is already True: that pushes a second,
    # redundant key onto the queue (the slot was already queued above by
    # the direct completed(True) call). Asserting the length makes the
    # double push visible and intended rather than accidental; settle()
    # below only consumes queue[0].
    p[].done = True
    p[].mark_owner_dropped()
    assert_equal(len(queue), 2, "mark_owner_dropped queues a second, redundant key")
    slab.settle(queue[0] >> _KIND_BITS)
    assert_equal(slab.active(), 0)
    assert_true(not slab.is_active(0), "settled slot is free")


def main() raises:
    test_slab_grows_in_chunks_and_keeps_addresses()
    print("ok: slab grows in chunks and keeps addresses")
    test_slot_is_queued_once_by_the_second_event()
    print("ok: slot is queued once, by the second event")
    test_freed_slot_is_reused_before_growing()
    print("ok: freed slot is reused before growing")
    test_detach_marks_live_handles_and_keeps_chunks()
    print("ok: detach marks live handles and keeps chunks")
    test_loop_completes_more_operations_than_one_chunk()
    print("ok: loop completes more operations than one chunk")
    test_loop_reuses_slots_across_rounds()
    print("ok: loop reuses slots across rounds")
    test_future_outliving_a_tiny_loop_reports_loop_gone()
    print("ok: future outliving a tiny loop reports loop gone")
    test_key_has_room_for_ten_kinds()
    print("ok: key has room for ten kinds")
    test_active_count_and_rearmed_link()
    print("ok: active count and rearmed link")
    print("PASS: test_slab.mojo")
