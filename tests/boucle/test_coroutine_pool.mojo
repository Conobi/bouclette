"""Tests for StackPool — verifies stack reuse via the pool constructor."""

from boucle.coroutine import (
    Coroutine as CoroHandle,
    StackPool,
    Yielder as CoroYielder,
    CoroutineBody as CoroBody,
)
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true


struct Counter(Movable, Deinitable):
    """Per-test counter accessed via the typed coroutine state."""

    var hits: Int

    def __init__(out self):
        """Initialize with zero hits."""
        self.hits = 0

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.hits = move.hits


def _body(mut y: CoroYielder[Counter]) raises:
    """Body that increments hits by 1, suspends, then adds 100."""
    y.state()[].hits += 1
    y.suspend()
    y.state()[].hits += 100


def test_pool_acquire_runs_body() raises:
    """Coroutine created with pool constructor runs body correctly."""
    var pool = StackPool(capacity=4)
    var ptr = unsafe_alloc[CoroHandle[Counter]](1).as_unsafe_any_origin()
    ptr.unsafe_write(CoroHandle[Counter](_body, Counter(), pool))

    ptr[].resume()
    assert_equal(ptr[].state()[].hits, 1, "body did not run")
    ptr[].resume()
    assert_equal(ptr[].state()[].hits, 101, "body did not resume")
    assert_true(ptr[].is_done(), "expected coro DONE")

    ptr.unsafe_take_pointee().close()
    ptr.unsafe_free()
    assert_equal(pool.idle_count(), 1, "close did not return stack to pool")


def test_pool_recycles_stack() raises:
    """After close + new creation, the pool reuses a cached stack."""
    var pool = StackPool(capacity=4)

    # First coroutine: run to completion and close (returns stack to pool)
    var ptr1 = unsafe_alloc[CoroHandle[Counter]](1).as_unsafe_any_origin()
    ptr1.unsafe_write(CoroHandle[Counter](_body, Counter(), pool))
    ptr1[].resume()
    ptr1[].resume()
    ptr1.unsafe_take_pointee().close()
    ptr1.unsafe_free()
    assert_equal(pool.idle_count(), 1, "first close should park one stack")

    # Second coroutine: should reuse the cached stack
    var ptr2 = unsafe_alloc[CoroHandle[Counter]](1).as_unsafe_any_origin()
    ptr2.unsafe_write(CoroHandle[Counter](_body, Counter(), pool))
    assert_equal(pool.idle_count(), 0, "acquire should take the cached stack")
    ptr2[].resume()
    ptr2[].resume()
    assert_equal(ptr2[].state()[].hits, 101, "second invocation did not run cleanly")
    ptr2.unsafe_take_pointee().close()
    ptr2.unsafe_free()
    assert_equal(pool.idle_count(), 1, "second close should park one stack")


def test_pool_capacity_cap() raises:
    """Beyond `capacity`, close destroys the surplus stack."""
    var pool = StackPool(capacity=2)

    var ptr1 = unsafe_alloc[CoroHandle[Counter]](1).as_unsafe_any_origin()
    var ptr2 = unsafe_alloc[CoroHandle[Counter]](1).as_unsafe_any_origin()
    var ptr3 = unsafe_alloc[CoroHandle[Counter]](1).as_unsafe_any_origin()
    ptr1.unsafe_write(CoroHandle[Counter](_body, Counter(), pool))
    ptr2.unsafe_write(CoroHandle[Counter](_body, Counter(), pool))
    ptr3.unsafe_write(CoroHandle[Counter](_body, Counter(), pool))

    # Run all to completion
    ptr1[].resume()
    ptr1[].resume()
    ptr2[].resume()
    ptr2[].resume()
    ptr3[].resume()
    ptr3[].resume()

    # Release first two — pool caches them
    ptr1.unsafe_take_pointee().close()
    ptr1.unsafe_free()
    ptr2.unsafe_take_pointee().close()
    ptr2.unsafe_free()
    assert_equal(pool.idle_count(), 2)

    # Release third — over capacity, stack destroyed instead of cached
    ptr3.unsafe_take_pointee().close()
    ptr3.unsafe_free()
    assert_equal(pool.idle_count(), 2, "cap should not have been exceeded")


def main() raises:
    test_pool_acquire_runs_body()
    test_pool_recycles_stack()
    test_pool_capacity_cap()
    print("test_coroutine_pool PASSED")
