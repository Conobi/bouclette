"""Tests for Timeout type."""

from boucle.timeout import Timeout
from std.testing import assert_equal
from std.sys.info import size_of


def test_timeout_default() raises:
    var t = Timeout()
    assert_equal(Int(t.seconds), 0)
    assert_equal(Int(t.nanoseconds), 0)


def test_timeout_explicit() raises:
    var t = Timeout(seconds=5, nanoseconds=123_456_789)
    assert_equal(Int(t.seconds), 5)
    assert_equal(Int(t.nanoseconds), 123_456_789)


def test_timeout_from_ms() raises:
    var t = Timeout.from_ms(1500)
    assert_equal(Int(t.seconds), 1)
    assert_equal(Int(t.nanoseconds), 500_000_000)


def test_timeout_from_ms_sub_second() raises:
    var t = Timeout.from_ms(42)
    assert_equal(Int(t.seconds), 0)
    assert_equal(Int(t.nanoseconds), 42_000_000)


def test_timeout_layout_matches_kernel_timespec() raises:
    """Timeout must be 16 bytes (same as __kernel_timespec) for zero-copy bitcast."""
    assert_equal(size_of[Timeout](), 16)


def main() raises:
    test_timeout_default()
    test_timeout_explicit()
    test_timeout_from_ms()
    test_timeout_from_ms_sub_second()
    test_timeout_layout_matches_kernel_timespec()
