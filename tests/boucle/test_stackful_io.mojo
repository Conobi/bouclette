"""Integration test: stackful coroutines + CompletionLoop.

Proves that a coroutine can yield while waiting for an I/O completion,
and be resumed by the callback once the kernel signals done.
"""

from boucle.coroutine import Coroutine as CoroHandle, Yielder as CoroYielder
from boucle.completion import CompletionLoop
from boucle.proactor.completion import Completion
from boucle.socle.ptr import null_ptr
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true, assert_equal


# ── Shared state ─────────────────────────────────────────────────────────────


struct SharedState:
    """Data shared between the coroutine body and the completion callback.

    Lives on the stack of the test function -- both sides hold raw
    pointers that remain valid for the duration of the test.
    """

    var coro_ptr: Pointer[CoroHandle, MutUntrackedOrigin]
    var io_result: Int32
    var coro_saw_result: Int32
    var coro_completed: Bool

    def __init__(out self):
        """Construct zeroed shared state."""
        self.coro_ptr = null_ptr[CoroHandle, MutUntrackedOrigin]()
        self.io_result = Int32(-999)
        self.coro_saw_result = Int32(-999)
        self.coro_completed = False


# ── Coroutine body ────────────────────────────────────────────────────────────


def coro_body(mut y: CoroYielder) raises:
    """Simulate waiting for an I/O completion.

    1. Yield to the caller (pretending to wait for kernel I/O).
    2. When resumed by the callback, read the result from shared state.
    3. Mark ourselves done.
    """
    var state = y.user_data().unsafe_bitcast[SharedState]()

    # Suspend -- the loop will resume us once the nop completes
    y.yield_to_caller()

    # Back here after callback calls resume()
    state[].coro_saw_result = state[].io_result
    state[].coro_completed = True


# ── Completion callback ──────────────────────────────────────────────────────


def _on_io_complete(
    ctx: Pointer[NoneType, MutAnyOrigin],
    result: Int32,
    flags: UInt32,
):
    """On completion: store result in shared state and resume the coroutine."""
    var state_ptr = Pointer[SharedState, MutAnyOrigin](
        unsafe_from_address=Int(ctx)
    )
    state_ptr[].io_result = result
    # Resume the coroutine -- it will read io_result and set coro_completed
    try:
        state_ptr[].coro_ptr[].resume()
    except:
        # Propagation is not supported in the callback;
        # coro_completed remains False so the assertion below will catch it.
        pass


# ── Test ──────────────────────────────────────────────────────────────────────


def test_coro_with_completion_loop() raises:
    """Submit a nop, resume a coroutine from the completion callback."""
    # Shared state lives on the stack -- both coroutine and callback share
    # it via raw pointers. The struct must outlive both.
    var state = SharedState()

    var state_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )
    var state_for_cb = Pointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )

    # Allocate CoroHandle on heap so @explicit_destroy doesn't conflict
    # with raising calls in the test body. Cleanup via take_pointee + destroy.
    var coro_heap = unsafe_alloc[CoroHandle](1).as_unsafe_any_origin()
    var h = CoroHandle(coro_body, user_data=state_ptr)
    coro_heap.unsafe_write(h^)

    # Wire the completion callback to shared state
    var loop = CompletionLoop(sq_entries=8)
    var cmp = Completion(invoke=_on_io_complete, context=state_for_cb)
    var cmp_ptr = Pointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    # Store coro address so the callback can call resume()
    state.coro_ptr = Pointer[CoroHandle, MutUntrackedOrigin](
        unsafe_from_address=Int(coro_heap)
    )

    # First resume: coroutine runs until yield_to_caller()
    coro_heap[].resume()
    assert_true(coro_heap[].can_resume(), "coro should be SUSPENDED after first resume")
    assert_true(not coro_heap[].is_done(), "coro must not be done yet")

    # Submit nop; completion callback will resume the coroutine
    loop.submit_nop(cmp_ptr)
    loop.tick(wait=True)

    # After tick() the callback has fired and resumed the coro to completion
    assert_true(coro_heap[].is_done(), "coro must be DONE after tick()")
    assert_equal(state.io_result, Int32(0))
    assert_equal(state.coro_saw_result, Int32(0))
    assert_true(
        state.coro_completed,
        "coroutine body must have set coro_completed",
    )

    # Explicit cleanup
    coro_heap.unsafe_take_pointee().destroy()
    coro_heap.unsafe_free()
    _ = cmp


def main() raises:
    test_coro_with_completion_loop()
    print("All stackful I/O tests passed.")
