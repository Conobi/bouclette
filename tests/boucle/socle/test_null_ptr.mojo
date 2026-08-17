from boucle.socle.ptr import null_ptr
from std.memory import UnsafePointer
from boucle.socle.linux.raw.ctypes import c_void
from std.testing import assert_equal


def test_null_ptr_addr_zero() raises:
    assert_equal(Int(null_ptr[c_void, StaticConstantOrigin]()), 0)
    assert_equal(Int(null_ptr[UInt32, StaticConstantOrigin]()), 0)
    assert_equal(Int(null_ptr[UInt8, MutAnyOrigin]()), 0)
    assert_equal(Int(null_ptr[NoneType, MutUntrackedOrigin]()), 0)


def main() raises:
    test_null_ptr_addr_zero()
    print("test_null_ptr: all 1 tests passed")
