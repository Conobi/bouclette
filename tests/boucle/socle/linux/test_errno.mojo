from boucle.socle.linux.errno import Errno, _check_for_errors
from std.testing import assert_true, assert_false


def test_errno() raises:
    # Construction from raw errno number
    var e = Errno(errno=13)
    assert_true(e is Errno.EACCES)
    assert_false(e is Errno.EPERM)

    # EAGAIN and EWOULDBLOCK are the same on Linux
    assert_true(Errno.EAGAIN is Errno.EWOULDBLOCK)

    # Different errors are not equal
    assert_false(Errno.EINVAL is Errno.ENOENT)

    # _check_for_errors passes on non-negative values
    _check_for_errors(Scalar[DType.int64](0))
    _check_for_errors(Scalar[DType.int64](42))

    # _check_for_errors raises on negative values (valid errno)
    var caught = False
    try:
        _check_for_errors(Scalar[DType.int64](-13))
    except:
        caught = True
    assert_true(caught)

    # _check_for_errors raises on out-of-range negative values
    var caught_oor = False
    try:
        _check_for_errors(Scalar[DType.int64](-5000))
    except e:
        caught_oor = True
        # The error message should indicate out-of-range
        assert_true("out of range" in String(e))
    assert_true(caught_oor)

    # Errno raises on out-of-range negated_errno (zero)
    var caught_zero = False
    try:
        _ = Errno(negated_errno=Int16(0))
    except:
        caught_zero = True
    assert_true(caught_zero)

    # Errno raises on out-of-range negated_errno (positive)
    var caught_pos = False
    try:
        _ = Errno(negated_errno=Int16(1))
    except:
        caught_pos = True
    assert_true(caught_pos)

    # Errno raises on out-of-range negated_errno (too negative)
    var caught_big = False
    try:
        _ = Errno(negated_errno=Int16(-5000))
    except:
        caught_big = True
    assert_true(caught_big)


def main() raises:
    test_errno()
    print("PASS: test_errno.mojo")
