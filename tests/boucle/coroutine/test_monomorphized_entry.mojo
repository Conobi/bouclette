"""Prove _coro_entry[State] monomorphization: distinct addresses, correct dispatch."""

from boucle.coroutine import Coroutine, Yielder, CoroutineBody
from boucle.coroutine.yielder import _coro_entry
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true, assert_equal


# ── State structs (different sizes defeat ICF) ───────────────────────────


struct StateSmall(Movable, Deinitable):
    """Small state -- 1 field (8 bytes). Defeats ICF via size difference."""

    var value: Int

    def __init__(out self):
        """Initialize with zero."""
        self.value = 0

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.value = move.value


struct StateLarge(Movable, Deinitable):
    """Large state -- 4 fields (32 bytes). Defeats ICF via size difference."""

    var a: Int
    var b: Int
    var c: Int
    var d: Int

    def __init__(out self):
        """Initialize all fields to zero."""
        self.a = 0
        self.b = 0
        self.c = 0
        self.d = 0

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.a = move.a
        self.b = move.b
        self.c = move.c
        self.d = move.d


# ── Body functions ───────────────────────────────────────────────────────


def _small_body(mut y: Yielder[StateSmall]) raises:
    """Set value = 42 and return."""
    y.state()[].value = 42


def _large_body(mut y: Yielder[StateLarge]) raises:
    """Set a=1, b=2, c=3, d=4 and return."""
    y.state()[].a = 1
    y.state()[].b = 2
    y.state()[].c = 3
    y.state()[].d = 4


# ── Tests ────────────────────────────────────────────────────────────────


def test_distinct_entry_addresses() raises:
    """Two different State types produce distinct _coro_entry addresses."""
    var entry_small = _coro_entry[StateSmall]
    var addr_small = Int(Pointer(to=entry_small).unsafe_bitcast[Int]()[])

    var entry_large = _coro_entry[StateLarge]
    var addr_large = Int(Pointer(to=entry_large).unsafe_bitcast[Int]()[])

    assert_true(
        addr_small != addr_large,
        "monomorphized _coro_entry addresses must differ",
    )


def test_correct_dispatch() raises:
    """Both State types dispatch to the correct body via their entry point."""
    # -- Small coroutine --
    var ptr_s = unsafe_alloc[Coroutine[StateSmall]](1).as_unsafe_any_origin()
    ptr_s.unsafe_write(Coroutine[StateSmall](_small_body, StateSmall()))

    ptr_s[].resume()
    assert_equal(ptr_s[].state()[].value, 42, "small body did not set value")
    assert_true(ptr_s[].is_done(), "small coro should be done")

    ptr_s.unsafe_take_pointee().close()
    ptr_s.unsafe_free()

    # -- Large coroutine --
    var ptr_l = unsafe_alloc[Coroutine[StateLarge]](1).as_unsafe_any_origin()
    ptr_l.unsafe_write(Coroutine[StateLarge](_large_body, StateLarge()))

    ptr_l[].resume()
    assert_equal(ptr_l[].state()[].a, 1, "large body did not set a")
    assert_equal(ptr_l[].state()[].b, 2, "large body did not set b")
    assert_equal(ptr_l[].state()[].c, 3, "large body did not set c")
    assert_equal(ptr_l[].state()[].d, 4, "large body did not set d")
    assert_true(ptr_l[].is_done(), "large coro should be done")

    ptr_l.unsafe_take_pointee().close()
    ptr_l.unsafe_free()


def main() raises:
    """Run all monomorphization tests."""
    test_distinct_entry_addresses()
    test_correct_dispatch()
    print("test_monomorphized_entry PASSED")
