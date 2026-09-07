"""Test pool fan-out and serialisation."""

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true
from boucle.pool.pool import WorkerPool
from boucle.pool._queue import WorkItem
from boucle.proactor.completion import Completion


struct _Item(Movable):
    """Per-work-item state shared between `work_fn` and its completion.

    Fields:
        index: The value `work_fn` returns, so a wrong-slot delivery is
               distinguishable from a wrong-value one.
        slot: Where the completion callback stores the delivered result.
        done_count: Shared counter the completion callback bumps, so the
                    poll loop below can tell when every item has landed.
    """

    var index: Int
    var slot: Pointer[Int, MutUntrackedOrigin]
    var done_count: Pointer[Int, MutUntrackedOrigin]

    def __init__(
        out self,
        *,
        index: Int,
        slot: Pointer[Int, MutUntrackedOrigin],
        done_count: Pointer[Int, MutUntrackedOrigin],
    ):
        """Bundle an item's index with its result slot and done counter."""
        self.index = index
        self.slot = slot
        self.done_count = done_count

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.index = move.index
        self.slot = move.slot
        self.done_count = move.done_count


def _on_item_complete(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
    result: Int,
    flags: UInt32,
):
    """Store the result in the item's slot and bump the done counter."""
    var item = ctx.unsafe_bitcast[_Item]()
    item[].slot[] = result
    item[].done_count[] += 1


def _blocking_return_index(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Return the index carried by the item's context."""
    var item = ctx.unsafe_bitcast[_Item]()
    return Int32(item[].index)


def _submit_and_verify(*, count: Int, thread_count: Int) raises:
    """Submit `count` items to a `thread_count`-thread pool and verify
    every item's result lands in its own slot.

    Polls `drain()` every 20ms, up to 50 times, firing completions as
    results arrive.

    Args:
        count: Number of work items to submit.
        thread_count: Number of worker threads in the pool.

    Raises:
        If any assertion fails, or the pool cannot be created.
    """
    var slots = unsafe_alloc[Int](count)
    for i in range(count):
        slots[unsafe_offset=i] = -1
    var done_count = 0
    var done_ptr = Pointer[Int, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=done_count))
    )

    var pool = WorkerPool(thread_count=thread_count)
    var items = unsafe_alloc[_Item](count)
    var completions = unsafe_alloc[Completion](count)
    for i in range(count):
        # `unsafe_write` (not `[unsafe_offset=i] = ...`) because this
        # memory is uninitialized: assigning through the `ref` that
        # `__getitem__` returns treats the slot as already holding a
        # live value, and clobbering that garbage crashes once more
        # than a couple of slots are involved.
        items.unsafe_offset(i).unsafe_write(
            _Item(index=i, slot=slots.unsafe_offset(i), done_count=done_ptr)
        )
        var item_ctx = items.unsafe_offset(i).unsafe_bitcast[NoneType]()
        completions.unsafe_offset(i).unsafe_write(
            Completion(invoke=_on_item_complete, context=item_ctx)
        )
        pool.submit(
            WorkItem(
                work_fn=_blocking_return_index,
                context=item_ctx,
                completion=completions.unsafe_offset(i),
            )
        )

    # Poll until all items complete.
    for _ in range(50):
        _ = external_call["usleep", Int32](Int32(20_000))
        var results = pool.drain()
        for j in range(len(results)):
            results[j].completion[].fire(Int(results[j].result), UInt32(0))
        if done_count == count:
            break

    assert_true(done_count == count, "not all items completed")
    for i in range(count):
        assert_true(slots[unsafe_offset=i] == i, "wrong result in slot")

    slots.unsafe_free()
    items.unsafe_free()
    completions.unsafe_free()


def test_fanout() raises:
    """Submit 10 items to a pool with 4 threads, verify all complete."""
    _submit_and_verify(count=10, thread_count=4)


def test_serialisation() raises:
    """Submit 4 items to a pool with 1 thread, verify all complete."""
    _submit_and_verify(count=4, thread_count=1)


def main() raises:
    test_fanout()
    print("PASS: fan-out (4 threads, 10 items)")
    test_serialisation()
    print("PASS: serialisation (1 thread, 4 items)")
