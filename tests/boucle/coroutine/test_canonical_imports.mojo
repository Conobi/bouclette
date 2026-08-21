"""Verify canonical import paths for boucle.coroutine work end-to-end."""

from boucle.coroutine import Coroutine, Yielder, StackPool, CoroutineBody
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true


struct _State(Movable, Deinitable):
    """Simple typed state for canonical import tests."""

    var value: Int

    def __init__(out self, value: Int):
        """Initialize with a given value."""
        self.value = value

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.value = move.value


def _increment_body(mut y: Yielder[_State]) raises:
    """Body that increments state.value by 10, suspends, then adds 5 more."""
    y.state()[].value += 10
    y.suspend()
    y.state()[].value += 5


def test_coroutine_canonical_names() raises:
    """Coroutine and Yielder work via their canonical names."""
    var ptr = unsafe_alloc[Coroutine[_State]](1).as_unsafe_any_origin()
    var h = Coroutine[_State](_increment_body, _State(0))
    ptr.unsafe_write(h^)

    assert_true(ptr[].can_resume())
    ptr[].resume()
    assert_equal(ptr[].state()[].value, 10)

    ptr[].resume()
    assert_equal(ptr[].state()[].value, 15)
    assert_true(ptr[].is_done())

    ptr.unsafe_take_pointee().close()
    ptr.unsafe_free()


def test_pool_canonical_names() raises:
    """StackPool works via its canonical name."""
    var pool = StackPool(capacity=4)
    var ptr = unsafe_alloc[Coroutine[_State]](1).as_unsafe_any_origin()
    var h = Coroutine[_State](_increment_body, _State(0), pool)
    ptr.unsafe_write(h^)

    ptr[].resume()
    assert_equal(ptr[].state()[].value, 10)

    ptr[].resume()
    assert_equal(ptr[].state()[].value, 15)
    assert_true(ptr[].is_done())

    ptr.unsafe_take_pointee().close()
    ptr.unsafe_free()


def main() raises:
    test_coroutine_canonical_names()
    test_pool_canonical_names()
