"""Test `WorkerPool` basic round-trip."""

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true
from boucle.pool.pool import WorkerPool
from boucle.pool._queue import WorkItem
from boucle.proactor.completion import Completion
from boucle.socle.ptr import null_ptr


struct ResultSlot:
    """Records a single completion result."""

    var result: Int

    def __init__(out self):
        """Construct a zeroed slot."""
        self.result = 0

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Completion callback: store the result."""
        var self_ptr = Pointer[ResultSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result


def _blocking_add_one(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Blocking work: return 42."""
    return Int32(42)


def main() raises:
    var pool = WorkerPool(thread_count=1)

    # Set up a Completion that records the result into `slot`.
    var slot = ResultSlot()
    var slot_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var c = unsafe_alloc[Completion](1)
    c.unsafe_write(
        Completion(invoke=ResultSlot.on_complete, context=slot_ctx)
    )

    # Submit work.
    pool.submit(
        WorkItem(
            work_fn=_blocking_add_one,
            context=null_ptr[NoneType, MutUntrackedOrigin](),
            completion=c,
        )
    )

    # Wait for the worker to finish.
    _ = external_call["usleep", Int32](Int32(100_000))

    var completed = pool.drain()
    for i in range(len(completed)):
        completed[i].completion[].fire(Int(completed[i].result), UInt32(0))

    assert_true(slot.result == 42, "expected result 42")

    c.unsafe_free()
    print("PASS: basic round-trip")
