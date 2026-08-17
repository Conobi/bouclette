"""Verify canonical import paths for boucle.coroutine work end-to-end."""

from boucle.coroutine import Coroutine, Yielder, CoroutinePool, CoroutineBody
from boucle.socle.ptr import null_ptr
from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc
from std.testing import assert_equal, assert_true


struct _State:
    var value: Int

    def __init__(out self, value: Int):
        self.value = value


def _increment_body(mut y: Yielder) raises:
    """Body that increments state.value by 10, yields, then adds 5 more."""
    var sp = UnsafePointer[_State, MutAnyOrigin](
        unsafe_from_address=Int(y.user_data())
    )
    sp[].value += 10
    y.yield_to_caller()
    sp[].value += 5


def test_coroutine_canonical_names() raises:
    """Coroutine and Yielder work via their canonical names."""
    var state = _State(0)
    var ud = UnsafePointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(UnsafePointer(to=state))
    )
    var ptr = alloc[Coroutine](1).as_unsafe_any_origin()
    var h = Coroutine(_increment_body, ud)
    ptr.init_pointee_move(h^)

    assert_true(ptr[].can_resume())
    ptr[].resume()
    assert_equal(state.value, 10)

    ptr[].resume()
    assert_equal(state.value, 15)
    assert_true(ptr[].is_done())

    ptr.take_pointee().destroy()
    ptr.free()


def test_pool_canonical_names() raises:
    """CoroutinePool works via its canonical name."""
    var state = _State(0)
    var ud = UnsafePointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(UnsafePointer(to=state))
    )
    var pool = CoroutinePool(capacity=4)
    var ptr = pool.acquire(_increment_body, ud)

    ptr[].resume()
    assert_equal(state.value, 10)

    ptr[].resume()
    assert_equal(state.value, 15)
    assert_true(ptr[].is_done())

    pool.release(ptr)


def main() raises:
    test_coroutine_canonical_names()
    test_pool_canonical_names()
