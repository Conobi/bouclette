from boucle.error import IOError
from boucle.socle.platform import Errno
from std.testing import assert_true, assert_false, assert_equal, assert_not_equal


def test_error() raises:
    var would_block = IOError(Errno.EAGAIN)
    assert_true(would_block.is_would_block())
    assert_false(would_block.is_connection_reset())
    assert_false(would_block.is_timed_out())

    # EWOULDBLOCK == EAGAIN on Linux x86_64
    var would_block2 = IOError(Errno.EWOULDBLOCK)
    assert_true(would_block2.is_would_block())

    var conn_reset = IOError(Errno.ECONNRESET)
    assert_true(conn_reset.is_connection_reset())
    assert_false(conn_reset.is_would_block())

    var conn_refused = IOError(Errno.ECONNREFUSED)
    assert_true(conn_refused.is_connection_refused())

    var broken_pipe = IOError(Errno.EPIPE)
    assert_true(broken_pipe.is_broken_pipe())

    var timed_out = IOError(Errno.ETIMEDOUT)
    assert_true(timed_out.is_timed_out())

    var interrupted = IOError(Errno.EINTR)
    assert_true(interrupted.is_interrupted())


def test_from_errno_accepts_both_signs() raises:
    """Kernels report negated errnos; users think in positive ones."""
    var negative = IOError.from_errno(-111)
    var positive = IOError.from_errno(111)
    assert_equal(negative.errno_value(), 111)
    assert_equal(positive.errno_value(), 111)
    assert_equal(negative, positive)
    assert_true(negative.is_connection_refused())
    assert_true(positive.is_connection_refused())


def test_from_errno_matches_errno_constructor() raises:
    assert_equal(IOError.from_errno(-11), IOError(Errno.EAGAIN))
    assert_equal(IOError.from_errno(32), IOError(Errno.EPIPE))
    assert_not_equal(IOError.from_errno(11), IOError(Errno.EPIPE))


def test_from_errno_zero_is_not_an_error() raises:
    """A zero errno means "no error"; every predicate must stay False."""
    var none = IOError.from_errno(0)
    assert_equal(none.errno_value(), 0)
    assert_false(none.is_would_block())
    assert_false(none.is_connection_reset())
    assert_false(none.is_connection_refused())
    assert_false(none.is_broken_pipe())
    assert_false(none.is_timed_out())
    assert_false(none.is_interrupted())
    assert_equal(String(none), "SUCCESS (0)")


def test_from_errno_unknown_number() raises:
    """An errno with no known name still round-trips its number."""
    var unknown = IOError.from_errno(-4093)
    assert_equal(unknown.errno_value(), 4093)
    assert_false(unknown.is_would_block())
    assert_equal(String(unknown), "UNKNOWN (4093)")


def test_write_to_names_the_errno() raises:
    assert_equal(String(IOError.from_errno(-111)), "ECONNREFUSED (111)")
    assert_equal(String(IOError(Errno.EAGAIN)), "EAGAIN (11)")
    assert_equal(String(IOError(Errno.ETIMEDOUT)), "ETIMEDOUT (110)")
    assert_equal(String(IOError.from_errno(-5)), "EIO (5)")


def _raise_socle_style(text: String) raises:
    """Mimic the socle layer, which reports failures as a negated-errno text."""
    raise text


def test_from_error_reads_the_socle_shape() raises:
    try:
        _raise_socle_style("-111")
    except e:
        assert_equal(IOError.from_error(e), IOError.from_errno(111))


def test_from_error_falls_back_to_einval() raises:
    """Text that is not an errno has no errno to report; EINVAL stands in."""
    try:
        _raise_socle_style("invalid file descriptor")
    except e:
        assert_equal(String(IOError.from_error(e)), "EINVAL (22)")


def _fail_with(errno: Int) raises IOError:
    raise IOError.from_errno(errno)


def test_ioerror_is_raisable() raises:
    """IOError must be usable as a typed raised error."""
    var caught = False
    try:
        _fail_with(-111)
    except e:
        caught = True
        assert_true(e.is_connection_refused())
        assert_equal(e.errno_value(), 111)
    assert_true(caught, "IOError should have been raised")


def main() raises:
    test_error()
    test_from_errno_accepts_both_signs()
    test_from_errno_matches_errno_constructor()
    test_from_errno_zero_is_not_an_error()
    test_from_errno_unknown_number()
    test_write_to_names_the_errno()
    test_from_error_reads_the_socle_shape()
    test_from_error_falls_back_to_einval()
    test_ioerror_is_raisable()
    print("PASS: test_error.mojo")
