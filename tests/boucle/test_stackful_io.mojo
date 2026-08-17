"""Integration test: stackful coroutines + CompletionLoop.

Proves that a coroutine can yield while waiting for an I/O completion,
and be resumed by the handler once the kernel signals done.
"""

from boucle.stackful import CoroHandle, CoroYielder
from boucle.completion import CompletionLoop, CompletionHandler
from boucle.socle.ptr import null_ptr
from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc
from std.testing import assert_true, assert_equal


# ── Shared state ─────────────────────────────────────────────────────────────


struct SharedState:
    """Data shared between the coroutine body and the CompletionHandler.

    Lives on the stack of the test function — both sides hold raw
    pointers that remain valid for the duration of the test.
    """

    var coro_ptr: UnsafePointer[CoroHandle, MutUntrackedOrigin]
    var io_token: UInt64
    var io_result: Int32
    var coro_saw_result: Int32
    var coro_completed: Bool

    def __init__(out self):
        self.coro_ptr = null_ptr[CoroHandle, MutUntrackedOrigin]()
        self.io_token = 0
        self.io_result = -999
        self.coro_saw_result = -999
        self.coro_completed = False


# ── Coroutine body ────────────────────────────────────────────────────────────


def coro_body(mut y: CoroYielder) raises:
    """Simulate waiting for an I/O completion.

    1. Yield to the caller (pretending to wait for kernel I/O).
    2. When resumed by the handler, read the result from shared state.
    3. Mark ourselves done.
    """
    var state = y.user_data().bitcast[SharedState]()

    # Suspend — the loop will resume us once the nop completes
    y.yield_to_caller()

    # Back here after handler calls resume()
    state[].coro_saw_result = state[].io_result
    state[].coro_completed = True


# ── CompletionHandler ─────────────────────────────────────────────────────────


struct IoHandler(CompletionHandler):
    """On completion: store result in shared state and resume the coroutine."""

    var state_ptr: UnsafePointer[SharedState, MutUntrackedOrigin]

    def __init__(
        out self,
        state_ptr: UnsafePointer[SharedState, MutUntrackedOrigin],
    ):
        self.state_ptr = state_ptr

    def __init__(out self, *, deinit take: Self):
        self.state_ptr = take.state_ptr

    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        self.state_ptr[].io_token = token
        self.state_ptr[].io_result = result
        # Resume the coroutine — it will read io_result and set coro_completed
        try:
            self.state_ptr[].coro_ptr[].resume()
        except:
            # Propagation is not supported in on_complete;
            # coro_completed remains False so the assertion below will catch it.
            pass


# ── Test ──────────────────────────────────────────────────────────────────────


def test_coro_with_completion_loop() raises:
    # Shared state lives on the stack — both coroutine and handler share it
    # via raw pointers.  The struct must outlive both.
    var state = SharedState()

    var state_ptr = UnsafePointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(UnsafePointer(to=state))
    )
    var state_for_handler = UnsafePointer[SharedState, MutUntrackedOrigin](
        unsafe_from_address=Int(UnsafePointer(to=state))
    )

    # Allocate CoroHandle on heap so @explicit_destroy doesn't conflict
    # with raising calls in the test body. Cleanup via take_pointee + destroy.
    var coro_heap = alloc[CoroHandle](1).as_unsafe_any_origin()
    var h = CoroHandle(coro_body, user_data=state_ptr)
    coro_heap.init_pointee_move(h^)

    # Wire the handler to shared state
    var loop = CompletionLoop(IoHandler(state_for_handler), sq_entries=8)

    # Store coro address so the handler can call resume()
    state.coro_ptr = UnsafePointer[CoroHandle, MutUntrackedOrigin](
        unsafe_from_address=Int(coro_heap)
    )

    # First resume: coroutine runs until yield_to_caller()
    coro_heap[].resume()
    assert_true(coro_heap[].can_resume(), "coro should be SUSPENDED after first resume")
    assert_true(not coro_heap[].is_done(), "coro must not be done yet")

    # Submit nop; on_complete will resume the coroutine
    loop.submit_nop(token=UInt64(77))
    loop.run()

    # After loop.run() the handler has fired and resumed the coro to completion
    assert_true(coro_heap[].is_done(), "coro must be DONE after loop.run()")
    assert_equal(state.io_token, UInt64(77))
    assert_equal(state.io_result, Int32(0))
    assert_equal(state.coro_saw_result, Int32(0))
    assert_true(
        state.coro_completed,
        "coroutine body must have set coro_completed",
    )

    # Explicit cleanup
    coro_heap.take_pointee().destroy()
    coro_heap.free()


def main() raises:
    test_coro_with_completion_loop()
    print("All stackful I/O tests passed.")
