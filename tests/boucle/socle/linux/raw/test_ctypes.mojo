from boucle.socle.linux.raw.ctypes import (
    c_char, c_schar, c_uchar,
    c_short, c_ushort,
    c_int, c_uint,
    c_long, c_ulong,
    c_longlong, c_ulonglong,
    c_float, c_double,
    c_void,
)
from std.testing import assert_equal
from std.sys.info import size_of


def test_ctypes() raises:
    assert_equal(size_of[c_char](), 1)
    assert_equal(size_of[c_schar](), 1)
    assert_equal(size_of[c_uchar](), 1)
    assert_equal(size_of[c_short](), 2)
    assert_equal(size_of[c_ushort](), 2)
    assert_equal(size_of[c_int](), 4)
    assert_equal(size_of[c_uint](), 4)
    assert_equal(size_of[c_long](), 8)
    assert_equal(size_of[c_ulong](), 8)
    assert_equal(size_of[c_longlong](), 8)
    assert_equal(size_of[c_ulonglong](), 8)
    assert_equal(size_of[c_float](), 4)
    assert_equal(size_of[c_double](), 8)
    assert_equal(size_of[c_void](), 1)


def main() raises:
    test_ctypes()
    print("PASS: test_ctypes.mojo")
