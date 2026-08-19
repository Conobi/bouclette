from boucle.ctypes import (
    c_void,
    c_char,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_size_t,
    c_ssize_t,
)
from boucle.completion import CQE_F_MORE, CQE_F_BUFFER, CQE_BUFFER_SHIFT
from std.sys.info import size_of
from std.testing import assert_equal, assert_true


def test_ctypes_reexports() raises:
    # c_void aliases Int8 in the raw layer (LP64 Linux convention used
    # so pointer arithmetic operates in bytes).
    assert_equal(size_of[c_void](), 1)
    assert_equal(size_of[c_char](), 1)
    assert_equal(size_of[c_int](), 4)
    assert_equal(size_of[c_uint](), 4)
    assert_equal(size_of[c_long](), 8)
    assert_equal(size_of[c_ulong](), 8)
    assert_equal(size_of[c_size_t](), 8)
    assert_equal(size_of[c_ssize_t](), 8)

    var v: c_void = 0
    assert_true(Int(v) == 0)

    # CQE flag re-exports from boucle.completion match kernel values.
    assert_equal(CQE_F_BUFFER, 1)
    assert_equal(CQE_F_MORE, 2)
    assert_equal(CQE_BUFFER_SHIFT, 16)


def main() raises:
    test_ctypes_reexports()
    print("PASS: test_ctypes_reexports.mojo")
