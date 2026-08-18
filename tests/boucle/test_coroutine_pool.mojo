"""Tests for CoroutinePool — verifies handle reuse and reset."""

from boucle.coroutine import (
    Coroutine as CoroHandle,
    CoroutinePool,
    Yielder as CoroYielder,
    CoroutineBody as CoroBody,
)
from std.memory import Pointer
from std.testing import assert_equal, assert_true


# Per-test counter accessed via user_data pointer.
struct Counter(Movable):
    var hits: Int

    def __init__(out self):
        self.hits = 0

    def __init__(out self, *, deinit move: Self):
        self.hits = move.hits


def _body(mut y: CoroYielder) raises -> None:
    var udata = y.user_data()
    var ctr = Pointer[Counter, MutUntrackedOrigin](
        unsafe_from_address=Int(udata)
    )
    ctr[].hits += 1
    y.yield_to_caller()
    ctr[].hits += 100


def test_pool_acquire_runs_body() raises:
    var pool = CoroutinePool(capacity=4)
    var ctr = Counter()
    var ctr_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=ctr))
    )
    var h = pool.acquire(_body, ctr_ptr)
    h[].resume()
    assert_equal(ctr.hits, 1, "body did not run")
    h[].resume()
    assert_equal(ctr.hits, 101, "body did not resume")
    assert_true(h[].is_done(), "expected coro DONE")
    pool.release(h)
    assert_equal(pool.idle_count(), 1, "release did not park handle")


def test_pool_recycles_handle() raises:
    """After release + acquire, the SAME pointer should come back —
    proving the handle (and stack) was recycled, not reallocated."""
    var pool = CoroutinePool(capacity=4)
    var ctr = Counter()
    var ctr_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=ctr))
    )
    var h1 = pool.acquire(_body, ctr_ptr)
    var addr1 = Int(h1)
    h1[].resume()
    h1[].resume()
    pool.release(h1)

    var h2 = pool.acquire(_body, ctr_ptr)
    var addr2 = Int(h2)
    assert_equal(addr2, addr1, "expected pool to recycle the same handle")
    h2[].resume()
    h2[].resume()
    assert_equal(ctr.hits, 202, "second invocation did not run cleanly")
    pool.release(h2)


def test_pool_capacity_cap() raises:
    """Beyond `capacity`, release destroys the surplus."""
    var pool = CoroutinePool(capacity=2)
    var ctr = Counter()
    var ctr_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=ctr))
    )
    var h1 = pool.acquire(_body, ctr_ptr)
    var h2 = pool.acquire(_body, ctr_ptr)
    var h3 = pool.acquire(_body, ctr_ptr)
    h1[].resume(); h1[].resume()
    h2[].resume(); h2[].resume()
    h3[].resume(); h3[].resume()
    pool.release(h1)
    pool.release(h2)
    assert_equal(pool.idle_count(), 2)
    pool.release(h3)  # over the cap → destroy
    assert_equal(pool.idle_count(), 2, "cap should not have been exceeded")


def main() raises:
    test_pool_acquire_runs_body()
    test_pool_recycles_handle()
    test_pool_capacity_cap()
    print("test_coroutine_pool PASSED")
