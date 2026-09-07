"""Test that a pool work item's completion fires through the epoll tick() path.

Covers spec test 6: the worker pool's wakeup fd is registered with the
epoll driver's own epoll instance, so a completed work item must be
observable through `EpollCompletionDriver.tick()`, the same dispatch path
sockets use, not just through `WorkerPool.drain()` directly.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true

from boucle.drivers.epoll_completion import EpollCompletionDriver
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


def _blocking_return_99(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Blocking work: return 99."""
    return Int32(99)


def test_pool_completion_fires_through_epoll_tick() raises:
    """A work item's completion fires when tick() sees the pool's wakeup fd.

    `_ensure_pool` registers the pool's wakeup eventfd with the driver's
    epoll instance under the UInt64.MAX sentinel data value. Once a
    worker thread finishes the submitted item and notifies that fd,
    `tick()` must recognise the sentinel, drain the pool and fire the
    item's `Completion` -- exactly as it would for a socket completion.
    """
    var driver = EpollCompletionDriver(capacity=64)
    driver._ensure_pool()

    var slot = ResultSlot()
    var slot_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var c = unsafe_alloc[Completion](1)
    c.unsafe_write(
        Completion(invoke=ResultSlot.on_complete, context=slot_ctx)
    )

    driver._state[].worker_pool.value().submit(
        WorkItem(
            work_fn=_blocking_return_99,
            context=null_ptr[NoneType, MutUntrackedOrigin](),
            completion=c,
        )
    )

    var dispatched = driver.tick(wait=True, timeout_ms=2000)

    assert_true(
        dispatched >= 1,
        "expected at least one dispatched completion, got "
        + String(dispatched),
    )
    assert_true(slot.result == 99, "expected result 99")

    c.unsafe_free()


def main() raises:
    test_pool_completion_fires_through_epoll_tick()
    print("PASS: pool completion fires through epoll tick")
