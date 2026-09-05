"""Tests for the kernel release parser and the uname wrapper."""

from std.testing import assert_equal, assert_false, assert_true

from boucle.socle.linux.uname import (
    KernelVersion,
    parse_kernel_release,
    kernel_release,
    kernel_version,
    UTSNAME_SIZE,
    UTSNAME_FIELD_LEN,
    UTSNAME_RELEASE_OFFSET,
)


def test_parse_distribution_release() raises:
    """A distribution release string parses to its major.minor pair."""
    var v = parse_kernel_release("6.8.0-45-generic")
    assert_equal(v.major, 6)
    assert_equal(v.minor, 8)


def test_parse_two_digit_minor() raises:
    """Minor numbers above 9 are read in full, not digit by digit."""
    var v = parse_kernel_release("5.19.17")
    assert_equal(v.major, 5)
    assert_equal(v.minor, 19)


def test_parse_major_only() raises:
    """A bare major number gives minor 0."""
    var v = parse_kernel_release("6")
    assert_equal(v.major, 6)
    assert_equal(v.minor, 0)


def test_parse_garbage_is_zero() raises:
    """Text that does not start with a number parses to 0.0."""
    var v = parse_kernel_release("abc")
    assert_equal(v.major, 0)
    assert_equal(v.minor, 0)


def test_at_least() raises:
    """The comparison checks the major number first, then the minor."""
    assert_true(KernelVersion(6, 0).at_least(6, 0))
    assert_true(KernelVersion(6, 1).at_least(5, 19))
    assert_true(KernelVersion(7, 0).at_least(6, 12))
    assert_false(KernelVersion(5, 19).at_least(6, 0))
    assert_false(KernelVersion(5, 18).at_least(5, 19))


def test_writable() raises:
    """A version renders as major.minor."""
    assert_equal(String(KernelVersion(6, 8)), "6.8")


def test_utsname_layout() raises:
    """`struct utsname` is six 65-byte fields; release is the third."""
    assert_equal(UTSNAME_FIELD_LEN, 65)
    assert_equal(UTSNAME_SIZE, 6 * 65)
    assert_equal(UTSNAME_RELEASE_OFFSET, 2 * 65)


def test_live_kernel_release() raises:
    """`uname(2)` returns a non-empty release containing a dot."""
    var rel = kernel_release()
    assert_true(rel.byte_length() > 0, "release must not be empty")
    assert_true(rel.find(".") > 0, "release must contain a dot: " + rel)


def test_live_kernel_version() raises:
    """The running kernel is at least 3.x, and the parse agrees with the string."""
    var v = kernel_version()
    assert_true(v.major >= 3, "unexpected major " + String(v.major))
    assert_true(kernel_release().startswith(String(v)))


def main() raises:
    test_parse_distribution_release()
    test_parse_two_digit_minor()
    test_parse_major_only()
    test_parse_garbage_is_zero()
    test_at_least()
    test_writable()
    test_utsname_layout()
    test_live_kernel_release()
    test_live_kernel_version()
    print("PASS: test_uname.mojo")
