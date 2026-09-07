"""Tests for `WorkerPool` destruction and post-shutdown safety.

Covers spec tests 4 (destroy while an item is in flight), 5 (destroy an
empty pool) and 9 (a pool created after a previous one was torn down
still works normally).
"""

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true
from std.time import perf_counter_ns

from boucle.pool.pool import WorkerPool
from boucle.pool._queue import WorkItem
from boucle.proactor.completion import Completion
from boucle.socle.ptr import null_ptr


def _blocking_sleep_200ms(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Sleep 200ms to simulate a slow blocking operation."""
    _ = external_call["usleep", Int32](Int32(200_000))
    return Int32(77)


def _blocking_noop(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Return immediately with a fixed result."""
    return Int32(0)


def test_destroy_with_items_in_flight() raises:
    """Destroying a pool while a slow item runs must not block on it.

    Teardown detaches the worker thread rather than joining it, so the
    slow item keeps running to completion on its own after the pool
    struct itself is gone. At the instant of destruction the item is
    already popped off the queue, so it is neither "pending" (cancelled
    by teardown) nor "completed" (drained and fired) — its completion is
    simply never fired. This test only pins that destruction returns
    promptly and the process survives the worker finishing afterwards.
    """
    var c = unsafe_alloc[Completion](1)
    c.unsafe_write(Completion())

    var pool = WorkerPool(thread_count=1)
    pool.submit(
        WorkItem(
            work_fn=_blocking_sleep_200ms,
            context=null_ptr[NoneType, MutUntrackedOrigin](),
            completion=c,
        )
    )

    var start = perf_counter_ns()
    _ = pool^
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    assert_true(
        elapsed_ms < 100, "destruction blocked: " + String(elapsed_ms)
    )

    # Let the detached worker finish its 200ms sleep and free the shared
    # queue on its own; this only checks that doing so does not crash.
    _ = external_call["usleep", Int32](Int32(300_000))
    c.unsafe_free()


def test_empty_destruction() raises:
    """Creating and destroying a pool with no submitted work is a no-op."""
    var pool = WorkerPool(thread_count=2)
    _ = pool^


def test_submit_after_shutdown() raises:
    """A pool created after a prior one was destroyed still works normally."""
    var pool1 = WorkerPool(thread_count=1)
    _ = pool1^

    var pool2 = WorkerPool(thread_count=1)
    var c = unsafe_alloc[Completion](1)
    c.unsafe_write(Completion())
    pool2.submit(
        WorkItem(
            work_fn=_blocking_noop,
            context=null_ptr[NoneType, MutUntrackedOrigin](),
            completion=c,
        )
    )
    _ = external_call["usleep", Int32](Int32(100_000))
    var completed = pool2.drain()
    assert_true(len(completed) == 1, "expected one completed item")
    for i in range(len(completed)):
        completed[i].completion[].fire(Int(completed[i].result), UInt32(0))
    c.unsafe_free()


def main() raises:
    test_destroy_with_items_in_flight()
    print("PASS: destroy with items in flight (no block)")
    test_empty_destruction()
    print("PASS: empty destruction")
    test_submit_after_shutdown()
    print("PASS: submit after shutdown")
