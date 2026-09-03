"""Tests for typed Coroutine[State] — resume, yield, error, move."""

from boucle.coroutine import Coroutine as CoroHandle, Yielder as CoroYielder, CoroutineBody
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true


# ── Shared state structs ──────────────────────────────────────────────────


struct _SingleYieldState(Movable, Deinitable):
    """State for the single-yield test."""

    var step: Int

    def __init__(out self, step: Int):
        """Initialize with a step counter."""
        self.step = step

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.step = move.step


struct _RunToCompletionState(Movable, Deinitable):
    """State for the run-to-completion test."""

    var value: Int

    def __init__(out self, value: Int):
        """Initialize with a value."""
        self.value = value

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.value = move.value


struct _CounterState(Movable, Deinitable):
    """State for the counter-based tests."""

    var counter: Int

    def __init__(out self, counter: Int):
        """Initialize with a counter."""
        self.counter = counter

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.counter = move.counter


struct _CumulativeState(Movable, Deinitable):
    """State for the cumulative-addition test."""

    var total: Int

    def __init__(out self, total: Int):
        """Initialize with a total."""
        self.total = total

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.total = move.total


struct _ErrorAfterYieldState(Movable, Deinitable):
    """State for the error-after-yield test."""

    var step: Int

    def __init__(out self, step: Int):
        """Initialize with a step counter."""
        self.step = step

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.step = move.step


struct _Unit(Movable, Deinitable):
    """Trivial state for coroutines that carry no data."""

    def __init__(out self):
        """Initialize a Unit value."""
        pass

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        pass


# ── Test helper ──────────────────────────────────────────────────────────


struct TestCoro[State: Movable & Deinitable](Movable):
    """Wraps a CoroHandle behind a pointer to manage lifetime manually.

    Since CoroHandle is @explicit_destroy, holding it directly in a
    raises-function causes the compiler to flag every raising call as a
    potential leak point. This wrapper stores the handle on the heap and
    provides the same resume/query API, with explicit cleanup via __deinit__.
    """

    var _ptr: Pointer[CoroHandle[Self.State], MutUntrackedOrigin]

    def __init__(
        out self,
        body: CoroutineBody[Self.State],
        var state: Self.State,
        stack_size: UInt = 65536,
    ) raises:
        """Allocate a coroutine on the heap with typed state.

        Args:
            body: The coroutine body function.
            state: The typed shared state (ownership transferred in).
            stack_size: Usable stack size in bytes.
        """
        self._ptr = Pointer[CoroHandle[Self.State], MutUntrackedOrigin](
            unsafe_from_address=Int(unsafe_alloc[CoroHandle[Self.State]](1))
        )
        var h = CoroHandle[Self.State](body, state^, stack_size)
        self._ptr.unsafe_write(h^)

    def __init__(out self, *, deinit move: Self):
        """Move constructor. Transfers the inner pointer."""
        self._ptr = move._ptr

    def __deinit__(deinit self):
        """Destroy the heap-allocated coroutine handle."""
        self._ptr.unsafe_take_pointee().close()
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

    def state(self) -> Pointer[Self.State, MutUntrackedOrigin]:
        """Access the typed shared state."""
        return self._ptr[].state()

    def raw_ptr(self) -> Pointer[CoroHandle[Self.State], MutUntrackedOrigin]:
        """Access the raw pointer (for tests that need the address)."""
        return self._ptr


# ── Body functions ────────────────────────────────────────────────────────


def _single_yield_body(mut y: CoroYielder[_SingleYieldState]) raises:
    """Body that sets step=1, suspends, then step=2."""
    y.state()[].step = 1
    y.suspend()
    y.state()[].step = 2


def _run_to_completion_body(mut y: CoroYielder[_RunToCompletionState]) raises:
    """Body that sets value=42 and returns."""
    y.state()[].value = 42


def _multiple_yields_body(mut y: CoroYielder[_CounterState]) raises:
    """Body that increments counter and yields five times."""
    for _ in range(5):
        y.state()[].counter += 1
        y.suspend()


def _cumulative_body(mut y: CoroYielder[_CumulativeState]) raises:
    """Body that adds 10, yields, adds 20, yields, adds 30."""
    y.state()[].total += 10
    y.suspend()
    y.state()[].total += 20
    y.suspend()
    y.state()[].total += 30


def _error_immediate_body(mut y: CoroYielder[_Unit]) raises:
    """Body that immediately raises."""
    raise "coroutine error"


def _error_after_yield_body(mut y: CoroYielder[_ErrorAfterYieldState]) raises:
    """Body that yields once, then raises."""
    y.state()[].step = 1
    y.suspend()
    y.state()[].step = 2
    raise "delayed error"


# ── Tests ─────────────────────────────────────────────────────────────────


def test_create_destroy() raises:
    """Create a coroutine and let __deinit__ clean it up without resuming."""
    var coro = TestCoro[_RunToCompletionState](
        _run_to_completion_body, _RunToCompletionState(0)
    )
    assert_true(coro.can_resume())
    assert_true(not coro.is_done())
    # coro goes out of scope in CREATED state -- __deinit__ handles cleanup


def test_single_yield() raises:
    """Resume once, check state, resume again, check final state."""
    var coro = TestCoro[_SingleYieldState](
        _single_yield_body, _SingleYieldState(0)
    )
    coro.resume()
    assert_equal(coro.state()[].step, 1)
    coro.resume()
    assert_equal(coro.state()[].step, 2)
    assert_true(coro.is_done())


def test_run_to_completion() raises:
    """Body runs straight through without yielding."""
    var coro = TestCoro[_RunToCompletionState](
        _run_to_completion_body, _RunToCompletionState(0)
    )
    coro.resume()
    assert_equal(coro.state()[].value, 42)
    assert_true(coro.is_done())


def test_multiple_yields() raises:
    """Resume five times, check counter increments each time."""
    var coro = TestCoro[_CounterState](
        _multiple_yields_body, _CounterState(0)
    )
    for i in range(1, 6):
        coro.resume()
        assert_equal(coro.state()[].counter, i)
    coro.resume()
    assert_true(coro.is_done())


def test_shared_state() raises:
    """Cumulative state mutation across multiple yields."""
    var coro = TestCoro[_CumulativeState](
        _cumulative_body, _CumulativeState(0)
    )
    coro.resume()
    assert_equal(coro.state()[].total, 10)
    coro.resume()
    assert_equal(coro.state()[].total, 30)
    coro.resume()
    assert_equal(coro.state()[].total, 60)
    assert_true(coro.is_done())


def test_error_propagation() raises:
    """Error raised immediately in body propagates through resume()."""
    var coro = TestCoro[_Unit](_error_immediate_body, _Unit())
    var caught = False
    try:
        coro.resume()
    except e:
        caught = "coroutine error" in String(e)
    assert_true(caught)
    assert_true(coro.is_done())


def test_error_after_yield() raises:
    """Error raised after one yield propagates on the second resume()."""
    var coro = TestCoro[_ErrorAfterYieldState](
        _error_after_yield_body, _ErrorAfterYieldState(0)
    )
    coro.resume()
    assert_equal(coro.state()[].step, 1)
    var caught = False
    try:
        coro.resume()
    except e:
        caught = "delayed error" in String(e)
    assert_equal(coro.state()[].step, 2)
    assert_true(caught)
    assert_true(coro.is_done())


def test_move_handle() raises:
    """CoroHandle move preserves stable _CoroInner address -- resume works after move."""
    var coro = TestCoro[_CounterState](
        _multiple_yields_body, _CounterState(0)
    )
    coro.resume()
    assert_equal(coro.state()[].counter, 1)
    # Move into a new variable
    var moved = coro^
    moved.resume()
    assert_equal(moved.state()[].counter, 2)
    moved.resume()
    assert_equal(moved.state()[].counter, 3)
    # Run to completion via the moved handle
    moved.resume()
    moved.resume()
    moved.resume()
    assert_true(moved.is_done())
    assert_equal(moved.state()[].counter, 5)


def _alternation_body(mut y: CoroYielder[_CounterState]) raises:
    """Body that increments counter three times with yields between."""
    y.state()[].counter += 1
    y.suspend()
    y.state()[].counter += 1
    y.suspend()
    y.state()[].counter += 1


def test_multiple_live_coros() raises:
    """Multiple live coroutines resumed in alternation -- the event loop pattern."""
    var coro_a = TestCoro[_CounterState](
        _alternation_body, _CounterState(0)
    )
    var coro_b = TestCoro[_CounterState](
        _alternation_body, _CounterState(0)
    )
    var coro_c = TestCoro[_CounterState](
        _alternation_body, _CounterState(0)
    )

    # Round 1: resume all -- each increments to 1 and yields
    coro_a.resume()
    coro_b.resume()
    coro_c.resume()
    assert_equal(coro_a.state()[].counter, 1)
    assert_equal(coro_b.state()[].counter, 1)
    assert_equal(coro_c.state()[].counter, 1)

    # Round 2: resume in different order
    coro_c.resume()
    coro_a.resume()
    coro_b.resume()
    assert_equal(coro_a.state()[].counter, 2)
    assert_equal(coro_b.state()[].counter, 2)
    assert_equal(coro_c.state()[].counter, 2)

    # Round 3: all run to completion
    coro_b.resume()
    coro_c.resume()
    coro_a.resume()
    assert_equal(coro_a.state()[].counter, 3)
    assert_equal(coro_b.state()[].counter, 3)
    assert_equal(coro_c.state()[].counter, 3)
    assert_true(coro_a.is_done())
    assert_true(coro_b.is_done())
    assert_true(coro_c.is_done())


def test_custom_stack_size() raises:
    """Custom stack_size parameter works (smaller than default)."""
    # 16KB stack -- well above what these trivial bodies need
    var coro = TestCoro[_RunToCompletionState](
        _run_to_completion_body,
        _RunToCompletionState(0),
        stack_size=16384,
    )
    coro.resume()
    assert_equal(coro.state()[].value, 42)
    assert_true(coro.is_done())


def _read_seeded_body(mut y: CoroYielder[_RunToCompletionState]) raises:
    """Body that reads state seeded by the caller before first resume."""
    assert_true(y.state()[].value == 99, "caller-seeded value not visible")
    y.state()[].value += 1


def test_caller_state_before_resume() raises:
    """Caller writes to state() before the first resume(); body observes it."""
    var coro = TestCoro[_RunToCompletionState](
        _read_seeded_body, _RunToCompletionState(0)
    )
    coro.state()[].value = 99
    coro.resume()
    assert_equal(coro.state()[].value, 100)
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
    test_caller_state_before_resume()
    print("All stackful tests passed.")
