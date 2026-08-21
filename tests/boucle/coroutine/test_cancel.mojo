"""Tests for cooperative cancellation of Coroutine[State]."""

from boucle.coroutine import (
    Coroutine as CoroHandle,
    Yielder as CoroYielder,
    CoroutineBody,
)
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true


# ── State structs ────────────────────────────────────────────────────────


struct _CancelState(Movable, Deinitable):
    """State tracking counter progress and whether cancellation was observed."""

    var counter: Int
    var saw_cancelled: Bool

    def __init__(out self):
        """Initialize with zero counter and unseen cancellation."""
        self.counter = 0
        self.saw_cancelled = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.counter = move.counter
        self.saw_cancelled = move.saw_cancelled


struct _Unit(Movable, Deinitable):
    """Trivial state for coroutines that carry no data."""

    def __init__(out self):
        """Initialize a Unit value."""
        pass

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        pass


# ── Test helper ──────────────────────────────────────────────────────────


struct _TestCoro[State: Movable & Deinitable](Movable):
    """Heap-allocated CoroHandle wrapper with cancel() support.

    Like TestCoro in test_stackful but adds cancel() forwarding and
    calls cancel() before close() in __deinit__ so suspended coroutines
    are safely drained on cleanup.
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
        """Cancel (if needed) and destroy the heap-allocated coroutine."""
        self._ptr[].cancel()
        self._ptr.unsafe_take_pointee().close()
        self._ptr.unsafe_free()

    def resume(mut self) raises:
        """Forward resume to the underlying CoroHandle."""
        self._ptr[].resume()

    def is_done(self) -> Bool:
        """Forward is_done to the underlying CoroHandle."""
        return self._ptr[].is_done()

    def cancel(mut self):
        """Forward cancel to the underlying CoroHandle."""
        self._ptr[].cancel()

    def state(self) -> Pointer[Self.State, MutUntrackedOrigin]:
        """Access the typed shared state."""
        return self._ptr[].state()


# ── Body functions ───────────────────────────────────────────────────────


def _cooperative_body(mut y: CoroYielder[_CancelState]) raises:
    """Body that checks is_cancelled() at each suspend point and exits early.

    Increments counter before each suspend. If cancelled, records the flag
    and returns without completing the remaining work.
    """
    y.state()[].counter = 1
    y.suspend()
    # After resume: check cancellation before doing more work
    if y.is_cancelled():
        y.state()[].saw_cancelled = True
        return
    y.state()[].counter = 2
    y.suspend()


def _multi_suspend_body(mut y: CoroYielder[_CancelState]) raises:
    """Body that suspends multiple times, recording cancellation on resume.

    Increments counter at each step. After each suspend, checks
    is_cancelled() and records it before returning.
    """
    y.state()[].counter = 1
    y.suspend()
    if y.is_cancelled():
        y.state()[].saw_cancelled = True
        return
    y.state()[].counter = 2
    y.suspend()
    if y.is_cancelled():
        y.state()[].saw_cancelled = True
        return
    y.state()[].counter = 3


def _run_to_done_body(mut y: CoroYielder[_CancelState]) raises:
    """Body that runs to completion immediately — no suspend points."""
    y.state()[].counter = 42


def _cancel_on_created_body(mut y: CoroYielder[_CancelState]) raises:
    """Body that checks is_cancelled() at the very start.

    If cancelled from CREATED state, the body still executes — it sees
    the flag immediately and records it.
    """
    if y.is_cancelled():
        y.state()[].saw_cancelled = True
        y.state()[].counter = 99
        return
    y.state()[].counter = 1
    y.suspend()


def _raises_on_cancel_body(mut y: CoroYielder[_CancelState]) raises:
    """Body that raises an error when it detects cancellation."""
    y.state()[].counter = 1
    y.suspend()
    if y.is_cancelled():
        y.state()[].saw_cancelled = True
        raise "cancelled by user"
    y.state()[].counter = 2


def _ignores_cancel_body(mut y: CoroYielder[_CancelState]) raises:
    """Body that suspends 3 times without ever checking is_cancelled().

    cancel() must loop-resume through all suspend points until the body
    completes naturally.
    """
    y.state()[].counter += 1
    y.suspend()
    y.state()[].counter += 1
    y.suspend()
    y.state()[].counter += 1
    y.suspend()
    y.state()[].counter += 1


# ── Tests ────────────────────────────────────────────────────────────────


def test_cancel_cooperative() raises:
    """Body checks is_cancelled() at suspend point and returns early."""
    var coro = _TestCoro[_CancelState](_cooperative_body, _CancelState())
    coro.resume()
    assert_equal(coro.state()[].counter, 1)
    assert_true(not coro.is_done())

    coro.cancel()
    assert_true(coro.is_done())
    # Body saw the flag and exited early — counter stayed at 1
    assert_equal(coro.state()[].counter, 1)
    assert_true(coro.state()[].saw_cancelled)


def test_cancel_on_suspended() raises:
    """Cancel on a suspended coroutine — body sees is_cancelled() on resume."""
    var coro = _TestCoro[_CancelState](_multi_suspend_body, _CancelState())
    coro.resume()
    assert_equal(coro.state()[].counter, 1)
    assert_true(not coro.is_done())

    coro.cancel()
    assert_true(coro.is_done())
    assert_true(coro.state()[].saw_cancelled)
    # Counter stayed at 1 because the body returned early on cancellation
    assert_equal(coro.state()[].counter, 1)


def test_cancel_on_done() raises:
    """Cancel on a completed coroutine is a safe no-op."""
    var coro = _TestCoro[_CancelState](_run_to_done_body, _CancelState())
    coro.resume()
    assert_true(coro.is_done())
    assert_equal(coro.state()[].counter, 42)

    # Second cancel — should be a no-op
    coro.cancel()
    assert_true(coro.is_done())
    assert_equal(coro.state()[].counter, 42)


def test_cancel_on_created() raises:
    """Cancel before any resume — body runs and sees is_cancelled() immediately."""
    var coro = _TestCoro[_CancelState](
        _cancel_on_created_body, _CancelState()
    )
    assert_true(not coro.is_done())

    coro.cancel()
    assert_true(coro.is_done())
    assert_true(coro.state()[].saw_cancelled)
    assert_equal(coro.state()[].counter, 99)


def test_cancel_body_raises() raises:
    """Swallows errors raised by the body on cancellation."""
    var coro = _TestCoro[_CancelState](
        _raises_on_cancel_body, _CancelState()
    )
    coro.resume()
    assert_equal(coro.state()[].counter, 1)

    # cancel() resumes the body, which raises — cancel swallows it
    coro.cancel()
    assert_true(coro.is_done())
    assert_true(coro.state()[].saw_cancelled)


def test_cancel_body_ignores_flag() raises:
    """Loop-resumes a body that never checks is_cancelled() until done."""
    var coro = _TestCoro[_CancelState](_ignores_cancel_body, _CancelState())
    coro.resume()
    assert_equal(coro.state()[].counter, 1)

    # cancel() will resume through the remaining 2 suspends + final work
    coro.cancel()
    assert_true(coro.is_done())
    # All four increments completed (body ran to natural completion)
    assert_equal(coro.state()[].counter, 4)


def main() raises:
    """Run all cancellation tests."""
    test_cancel_cooperative()
    test_cancel_on_suspended()
    test_cancel_on_done()
    test_cancel_on_created()
    test_cancel_body_raises()
    test_cancel_body_ignores_flag()
    print("test_cancel PASSED")
