"""Callback re-submit and concurrent-load tests for `WorkerPool`.

Covers spec tests 3 (submitting work from inside a completion callback
must not deadlock) and 8 (a 4-thread pool completes 100 concurrently
submitted items).
"""

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true

from boucle.pool.pool import WorkerPool
from boucle.pool._queue import WorkItem
from boucle.proactor.completion import Completion
from boucle.socle.ptr import null_ptr


# ── test_callback_resubmit ─────────────────────────────────────────────


struct _ResubmitState(Movable):
    """Shared state reachable from inside the chained completion callbacks.

    Module-level `var` does not work in Mojo, so the pool the first
    callback resubmits to — and the counter the poll loop below watches —
    are reached through this heap-allocated struct instead.

    Fields:
        pool: Pointer to the pool the first callback resubmits work to.
        second_completion: The re-submitted item's completion, wired up
                            front so the first callback's resubmit has
                            somewhere to point it.
        fired_count: Bumped by each callback. Heap-allocated so every
                     read goes through the pointer, the same fix
                     `test_concurrent_100_items` uses for its counter.
    """

    var pool: Pointer[WorkerPool, MutUntrackedOrigin]
    var second_completion: Pointer[Completion, MutUntrackedOrigin]
    var fired_count: Pointer[Int, MutUntrackedOrigin]

    def __init__(
        out self,
        *,
        pool: Pointer[WorkerPool, MutUntrackedOrigin],
        second_completion: Pointer[Completion, MutUntrackedOrigin],
        fired_count: Pointer[Int, MutUntrackedOrigin],
    ):
        """Bundle the pool, the second completion, and the fire counter."""
        self.pool = pool
        self.second_completion = second_completion
        self.fired_count = fired_count

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.pool = move.pool
        self.second_completion = move.second_completion
        self.fired_count = move.fired_count


def _blocking_return_1(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Blocking work: return 1, regardless of context."""
    return Int32(1)


def _on_second_complete(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
    result: Int,
    flags: UInt32,
):
    """Second callback: record that the re-submitted item completed."""
    var state = ctx.unsafe_bitcast[_ResubmitState]()
    state[].fired_count[] += 1


def _on_first_complete(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
    result: Int,
    flags: UInt32,
):
    """First callback: submit a second work item to the same pool.

    This runs from the loop thread after `drain()` has already released
    the queue's mutex, so resubmitting here must not deadlock (spec
    test 3). `Completion.invoke` may not raise, so a submission failure
    is swallowed rather than propagated.
    """
    var state = ctx.unsafe_bitcast[_ResubmitState]()
    state[].fired_count[] += 1
    try:
        state[].pool[].submit(
            WorkItem(
                work_fn=_blocking_return_1,
                context=null_ptr[NoneType, MutUntrackedOrigin](),
                completion=state[].second_completion,
            )
        )
    except:
        pass


def test_callback_resubmit() raises:
    """Submitting work from inside a completion callback must not deadlock."""
    var pool = WorkerPool(thread_count=2)

    var fired_count = unsafe_alloc[Int](1)
    fired_count.unsafe_write(0)

    var c1 = unsafe_alloc[Completion](1)
    var c2 = unsafe_alloc[Completion](1)

    var state = unsafe_alloc[_ResubmitState](1)
    state.unsafe_write(
        _ResubmitState(
            pool=Pointer[WorkerPool, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=pool))
            ),
            second_completion=c2,
            fired_count=fired_count,
        )
    )
    var state_ctx = state.unsafe_bitcast[NoneType]()

    c1.unsafe_write(Completion(invoke=_on_first_complete, context=state_ctx))
    c2.unsafe_write(Completion(invoke=_on_second_complete, context=state_ctx))

    pool.submit(
        WorkItem(
            work_fn=_blocking_return_1,
            context=null_ptr[NoneType, MutUntrackedOrigin](),
            completion=c1,
        )
    )

    # Poll until both completions have fired: the first directly, the
    # second only after the first's callback resubmits it.
    for _ in range(100):
        _ = external_call["usleep", Int32](Int32(20_000))
        var results = pool.drain()
        for j in range(len(results)):
            results[j].completion[].fire(Int(results[j].result), UInt32(0))
        if fired_count[] == 2:
            break

    assert_true(fired_count[] == 2, "both completions should have fired")

    c1.unsafe_free()
    c2.unsafe_free()
    state.unsafe_free()
    fired_count.unsafe_free()
    _ = pool^


# ── test_concurrent_100_items ───────────────────────────────────────────


def _blocking_return_42(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Blocking work: return 42, regardless of context."""
    return Int32(42)


def _on_concurrent_complete(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
    result: Int,
    flags: UInt32,
):
    """Increment the shared, heap-allocated completion counter."""
    var counter = ctx.unsafe_bitcast[Int]()
    counter[] += 1


def test_concurrent_100_items() raises:
    """Submit 100 items to a 4-thread pool; all must complete (spec test 8)."""
    var pool = WorkerPool(thread_count=4)

    # Heap-allocated, not a local `var`: reading a local through a
    # separate alias pointer let the compiler cache a stale value across
    # the poll loop in an earlier draft of this test. Every read here
    # goes through `counter` itself.
    var counter = unsafe_alloc[Int](1)
    counter.unsafe_write(0)
    var counter_ctx = counter.unsafe_bitcast[NoneType]()

    var completions = unsafe_alloc[Completion](100)
    for i in range(100):
        completions.unsafe_offset(i).unsafe_write(
            Completion(invoke=_on_concurrent_complete, context=counter_ctx)
        )
        pool.submit(
            WorkItem(
                work_fn=_blocking_return_42,
                context=null_ptr[NoneType, MutUntrackedOrigin](),
                completion=completions.unsafe_offset(i),
            )
        )

    # Poll until every item has completed.
    for _ in range(200):
        _ = external_call["usleep", Int32](Int32(10_000))
        var results = pool.drain()
        for j in range(len(results)):
            results[j].completion[].fire(Int(results[j].result), UInt32(0))
        if counter[] == 100:
            break

    assert_true(counter[] == 100, "all 100 items should complete")

    completions.unsafe_free()
    counter.unsafe_free()
    _ = pool^


def main() raises:
    test_callback_resubmit()
    print("PASS: callback re-submit (no deadlock)")
    test_concurrent_100_items()
    print("PASS: concurrent (4 threads, 100 items)")
