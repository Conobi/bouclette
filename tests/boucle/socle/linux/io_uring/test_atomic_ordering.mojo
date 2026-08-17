from boucle.socle.linux.io_uring.utils import (
    _atomic_load,
    _atomic_store,
    AtomicOrdering,
)
from std.memory import UnsafePointer, alloc
from std.testing import assert_equal


def test_atomic_store_then_load_roundtrip() raises:
    # The helpers take an `UnsafePointer[Scalar[type], StaticConstantOrigin]`
    # (modelling kernel-shared io_uring ring memory). Build one by allocating a
    # mutable cell and coercing its origin: mutable -> immutable ->
    # StaticConstantOrigin (b2 removed `origin_cast`).
    var owner = alloc[UInt32](1)
    var p = owner.unsafe_mut_cast[False]().unsafe_origin_cast[
        StaticConstantOrigin
    ]()

    _atomic_store(p, UInt32(42))
    assert_equal(_atomic_load[ordering = AtomicOrdering.ACQUIRE](p), UInt32(42))
    assert_equal(_atomic_load[ordering = AtomicOrdering.RELAXED](p), UInt32(42))

    _atomic_store(p, UInt32(7))
    assert_equal(_atomic_load[ordering = AtomicOrdering.ACQUIRE](p), UInt32(7))

    owner.free()


def main() raises:
    test_atomic_store_then_load_roundtrip()
    print("test_atomic_ordering: passed")
