"""Integration test: stackful coroutines + CompletionLoop.

Proves that a coroutine can yield while waiting for an I/O completion,
and be resumed by the callback once the kernel signals done.
"""

from boucle.coroutine import Coroutine as CoroHandle, Yielder as CoroYielder
from boucle.completion import CompletionLoop
from boucle.proactor.completion import Completion
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true, assert_equal


# ── Shared state ─────────────────────────────────────────────────────────────


struct IoState(Movable, Deinitable):
    """Data shared between the coroutine body and the completion callback.

    Owned by the coroutine -- both the body (via Yielder.state()) and
    the callback (via Coroutine.state()) access the same fields through
    typed pointers that remain valid for the duration of the test.
    """

    var io_result: Int
    var coro_saw_result: Int
    var coro_completed: Bool

    def __init__(out self):
        """Construct zeroed I/O state."""
        self.io_result = -999
        self.coro_saw_result = -999
        self.coro_completed = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.io_result = move.io_result
        self.coro_saw_result = move.coro_saw_result
        self.coro_completed = move.coro_completed


# ── Coroutine body ────────────────────────────────────────────────────────────


def coro_body(mut y: CoroYielder[IoState]) raises:
    """Simulate waiting for an I/O completion.

    1. Suspend to the caller (pretending to wait for kernel I/O).
    2. When resumed by the callback, read the result from typed state.
    3. Mark ourselves done.
    """
    # Suspend -- the loop will resume us once the nop completes
    y.suspend()

    # Back here after callback calls resume()
    y.state()[].coro_saw_result = y.state()[].io_result
    y.state()[].coro_completed = True


# ── Completion callback ──────────────────────────────────────────────────────


def _on_io_complete(
    ctx: Pointer[NoneType, MutUntrackedOrigin],
    result: Int,
    flags: UInt32,
):
    """On completion: store result in the coroutine's state and resume it.

    Args:
        ctx: Pointer to the heap-allocated Coroutine[IoState].
        result: The I/O completion result code.
        flags: Completion flags (unused).
    """
    var coro_ptr = Pointer[CoroHandle[IoState], MutUntrackedOrigin](
        unsafe_from_address=Int(ctx)
    )
    coro_ptr[].state()[].io_result = result
    # Resume the coroutine -- it will read io_result and set coro_completed
    try:
        coro_ptr[].resume()
    except:
        # Propagation is not supported in the callback;
        # coro_completed remains False so the assertion below will catch it.
        pass


# ── Test ──────────────────────────────────────────────────────────────────────


def test_coro_with_completion_loop() raises:
    """Submit a nop, resume a coroutine from the completion callback."""
    # Allocate CoroHandle on heap so @explicit_destroy doesn't conflict
    # with raising calls in the test body. Cleanup via take_pointee + close.
    var coro_heap = unsafe_alloc[CoroHandle[IoState]](1).as_unsafe_any_origin()
    coro_heap.unsafe_write(CoroHandle[IoState](coro_body, IoState()))

    # Callback context = pointer to the coroutine on the heap
    var cb_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(coro_heap)
    )

    var loop = CompletionLoop(sq_entries=8)
    var cmp = Completion(invoke=_on_io_complete, context=cb_ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    # First resume: coroutine runs until suspend()
    coro_heap[].resume()
    assert_true(
        coro_heap[].can_resume(),
        "coro should be SUSPENDED after first resume",
    )
    assert_true(not coro_heap[].is_done(), "coro must not be done yet")

    # Submit nop; completion callback will resume the coroutine
    loop.nop(cmp_ptr)
    _ = loop.tick(wait=True)

    # After tick() the callback has fired and resumed the coro to completion
    assert_true(coro_heap[].is_done(), "coro must be DONE after tick()")
    var s = coro_heap[].state()
    assert_equal(s[].io_result, 0)
    assert_equal(s[].coro_saw_result, 0)
    assert_true(
        s[].coro_completed,
        "coroutine body must have set coro_completed",
    )

    # Explicit cleanup
    coro_heap.unsafe_take_pointee().close()
    coro_heap.unsafe_free()
    _ = cmp


def main() raises:
    test_coro_with_completion_loop()
    print("All stackful I/O tests passed.")
