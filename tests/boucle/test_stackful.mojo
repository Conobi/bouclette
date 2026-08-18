from boucle.coroutine import Coroutine as CoroHandle, Yielder as CoroYielder
from boucle.socle.ptr import null_ptr
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true


# ── Shared state structs ──────────────────────────────────────────────────


struct _CreateDestroyState:
    var checked: Bool

    def __init__(out self):
        self.checked = False


struct _SingleYieldState:
    var step: Int

    def __init__(out self, step: Int):
        self.step = step


struct _RunToCompletionState:
    var value: Int

    def __init__(out self, value: Int):
        self.value = value


struct _CounterState:
    var counter: Int

    def __init__(out self, counter: Int):
        self.counter = counter


struct _CumulativeState:
    var total: Int

    def __init__(out self, total: Int):
        self.total = total


struct _ErrorAfterYieldState:
    var step: Int

    def __init__(out self, step: Int):
        self.step = step


# ── Test helper ──────────────────────────────────────────────────────────


struct TestCoro(Movable):
    """Wraps a CoroHandle behind a pointer to manage lifetime manually.

    Since CoroHandle is @explicit_destroy, holding it directly in a
    raises-function causes the compiler to flag every raising call as a
    potential leak point. This wrapper stores the handle on the heap and
    provides the same resume/query API, with explicit cleanup via close().
    """

    var _ptr: Pointer[CoroHandle, MutUntrackedOrigin]

    def __init__(
        out self,
        body: def (mut CoroYielder) thin raises -> None,
        user_data: Pointer[NoneType, MutUntrackedOrigin] = null_ptr[NoneType, MutUntrackedOrigin](),
        stack_size: UInt = 65536,
    ) raises:
        self._ptr = Pointer[CoroHandle, MutUntrackedOrigin](unsafe_from_address=Int(unsafe_alloc[CoroHandle](1)))
        var h = CoroHandle(body, user_data, stack_size)
        self._ptr.unsafe_write(h^)

    def __init__(out self, *, deinit move: Self):
        self._ptr = move._ptr

    def __deinit__(deinit self):
        self._ptr.unsafe_take_pointee().destroy()
        self._ptr.unsafe_free()

    def resume(mut self) raises:
        """Forward resume to the underlying CoroHandle."""
        self._ptr[].resume()

    def is_done(self) -> Bool:
        """Forward is_done to the underlying CoroHandle."""
        return self._ptr[].is_done()

    def can_resume(self) -> Bool:
        """Forward can_resume to the underlying CoroHandle."""
        return self._ptr[].can_resume()

    def raw_ptr(self) -> Pointer[CoroHandle, MutUntrackedOrigin]:
        """Access the raw pointer (for tests that need the address)."""
        return self._ptr


# ── Body functions ────────────────────────────────────────────────────────


def _single_yield_body(mut y: CoroYielder) raises:
    var state = y.user_data().unsafe_bitcast[_SingleYieldState]()
    state[].step = 1
    y.yield_to_caller()
    state[].step = 2


def _run_to_completion_body(mut y: CoroYielder) raises:
    var state = y.user_data().unsafe_bitcast[_RunToCompletionState]()
    state[].value = 42


def _multiple_yields_body(mut y: CoroYielder) raises:
    var state = y.user_data().unsafe_bitcast[_CounterState]()
    for _ in range(5):
        state[].counter += 1
        y.yield_to_caller()


def _cumulative_body(mut y: CoroYielder) raises:
    var state = y.user_data().unsafe_bitcast[_CumulativeState]()
    state[].total += 10
    y.yield_to_caller()
    state[].total += 20
    y.yield_to_caller()
    state[].total += 30


def _error_immediate_body(mut y: CoroYielder) raises:
    raise "coroutine error"


def _error_after_yield_body(mut y: CoroYielder) raises:
    var state = y.user_data().unsafe_bitcast[_ErrorAfterYieldState]()
    state[].step = 1
    y.yield_to_caller()
    state[].step = 2
    raise "delayed error"


# ── Tests ─────────────────────────────────────────────────────────────────


def test_create_destroy() raises:
    var coro = TestCoro(_run_to_completion_body)
    assert_true(coro.can_resume())
    assert_true(not coro.is_done())
    # coro goes out of scope in CREATED state -- __deinit__ handles cleanup


def test_single_yield() raises:
    var state = _SingleYieldState(0)
    var state_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )
    var coro = TestCoro(_single_yield_body, user_data=state_ptr)
    coro.resume()
    assert_equal(state.step, 1)
    coro.resume()
    assert_equal(state.step, 2)
    assert_true(coro.is_done())


def test_run_to_completion() raises:
    var state = _RunToCompletionState(0)
    var state_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )
    var coro = TestCoro(_run_to_completion_body, user_data=state_ptr)
    coro.resume()
    assert_equal(state.value, 42)
    assert_true(coro.is_done())


def test_multiple_yields() raises:
    var state = _CounterState(0)
    var state_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )
    var coro = TestCoro(_multiple_yields_body, user_data=state_ptr)
    for i in range(1, 6):
        coro.resume()
        assert_equal(state.counter, i)
    coro.resume()
    assert_true(coro.is_done())


def test_shared_state() raises:
    var state = _CumulativeState(0)
    var state_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )
    var coro = TestCoro(_cumulative_body, user_data=state_ptr)
    coro.resume()
    assert_equal(state.total, 10)
    coro.resume()
    assert_equal(state.total, 30)
    coro.resume()
    assert_equal(state.total, 60)
    assert_true(coro.is_done())


def test_error_propagation() raises:
    var coro = TestCoro(_error_immediate_body)
    var caught = False
    try:
        coro.resume()
    except e:
        caught = "coroutine error" in String(e)
    assert_true(caught)
    assert_true(coro.is_done())


def test_error_after_yield() raises:
    var state = _ErrorAfterYieldState(0)
    var state_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )
    var coro = TestCoro(_error_after_yield_body, user_data=state_ptr)
    coro.resume()
    assert_equal(state.step, 1)
    var caught = False
    try:
        coro.resume()
    except e:
        caught = "delayed error" in String(e)
    assert_equal(state.step, 2)
    assert_true(caught)
    assert_true(coro.is_done())


def test_move_handle() raises:
    """CoroHandle move preserves stable _CoroInner address — resume works after move."""
    var state = _CounterState(0)
    var state_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )
    var coro = TestCoro(_multiple_yields_body, user_data=state_ptr)
    coro.resume()
    assert_equal(state.counter, 1)
    # Move into a new variable
    var moved = coro^
    moved.resume()
    assert_equal(state.counter, 2)
    moved.resume()
    assert_equal(state.counter, 3)
    # Run to completion via the moved handle
    moved.resume()
    moved.resume()
    moved.resume()
    assert_true(moved.is_done())
    assert_equal(state.counter, 5)


def _alternation_body(mut y: CoroYielder) raises:
    var state = y.user_data().unsafe_bitcast[_CounterState]()
    state[].counter += 1
    y.yield_to_caller()
    state[].counter += 1
    y.yield_to_caller()
    state[].counter += 1


def test_multiple_live_coros() raises:
    """Multiple live coroutines resumed in alternation — the event loop pattern."""
    var state_a = _CounterState(0)
    var state_b = _CounterState(0)
    var state_c = _CounterState(0)
    var ptr_a = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state_a))
    )
    var ptr_b = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state_b))
    )
    var ptr_c = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state_c))
    )
    var coro_a = TestCoro(_alternation_body, user_data=ptr_a)
    var coro_b = TestCoro(_alternation_body, user_data=ptr_b)
    var coro_c = TestCoro(_alternation_body, user_data=ptr_c)

    # Round 1: resume all — each increments to 1 and yields
    coro_a.resume()
    coro_b.resume()
    coro_c.resume()
    assert_equal(state_a.counter, 1)
    assert_equal(state_b.counter, 1)
    assert_equal(state_c.counter, 1)

    # Round 2: resume in different order
    coro_c.resume()
    coro_a.resume()
    coro_b.resume()
    assert_equal(state_a.counter, 2)
    assert_equal(state_b.counter, 2)
    assert_equal(state_c.counter, 2)

    # Round 3: all run to completion
    coro_b.resume()
    coro_c.resume()
    coro_a.resume()
    assert_equal(state_a.counter, 3)
    assert_equal(state_b.counter, 3)
    assert_equal(state_c.counter, 3)
    assert_true(coro_a.is_done())
    assert_true(coro_b.is_done())
    assert_true(coro_c.is_done())


def test_custom_stack_size() raises:
    """Custom stack_size parameter works (smaller than default)."""
    var state = _RunToCompletionState(0)
    var state_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )
    # 16KB stack — well above what these trivial bodies need
    var coro = TestCoro(
        _run_to_completion_body, user_data=state_ptr, stack_size=16384
    )
    coro.resume()
    assert_equal(state.value, 42)
    assert_true(coro.is_done())


def main() raises:
    test_create_destroy()
    test_single_yield()
    test_run_to_completion()
    test_multiple_yields()
    test_shared_state()
    test_error_propagation()
    test_error_after_yield()
    test_move_handle()
    test_multiple_live_coros()
    test_custom_stack_size()
    print("All stackful tests passed.")
