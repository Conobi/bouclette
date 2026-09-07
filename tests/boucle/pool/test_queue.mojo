"""Test `_WorkQueue` push/pop/shutdown lifecycle."""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true
from boucle.pool._queue import WorkItem, _CompletedWork, _WorkQueue
from boucle.pool._notify import create_eventfd
from boucle.proactor.completion import Completion
from boucle.socle.ptr import null_ptr


def _noop_work(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """No-op work function."""
    return Int32(0)


def main() raises:
    var efd = create_eventfd()
    var q = unsafe_alloc[_WorkQueue](1)
    q.unsafe_write(_WorkQueue(wakeup_fd=efd, thread_count=1))

    # Push an item.
    var c = unsafe_alloc[Completion](1)
    c.unsafe_write(Completion())
    var item = WorkItem(
        work_fn=_noop_work,
        context=null_ptr[NoneType, MutUntrackedOrigin](),
        completion=c,
    )
    q[].push(item^)

    # Pop it back.
    var popped = q[].pop()
    assert_true(popped.__bool__(), "pop returned None before shutdown")

    # Push a result.
    var result = _CompletedWork(completion=c, result=Int32(42))
    q[].push_result(result^)

    # Drain results.
    var results = q[].drain_results()
    assert_true(len(results) == 1, "expected 1 result")
    assert_true(results[0].result == Int32(42), "wrong result value")

    # Shutdown: pop returns None.
    q[].shutdown()
    var after = q[].pop()
    assert_true(not after.__bool__(), "pop should return None after shutdown")

    # Cancel pending (empty after our pop).
    var cancelled = q[].cancel_pending()
    assert_true(len(cancelled) == 0, "nothing to cancel")

    # thread_exited: last thread frees nothing (we handle it).
    var is_last = q[].thread_exited()
    assert_true(is_last, "should be last with thread_count=1")

    # Clean up (we're the last, so we free).
    q.unsafe_deinit_pointee()
    q.unsafe_free()
    c.unsafe_free()

    print("PASS: _WorkQueue push/pop/shutdown lifecycle")
