from boucle.interest import Interest
from std.testing import assert_true, assert_false, assert_equal


def test_interest() raises:
    assert_true(Interest.READABLE.is_readable())
    assert_false(Interest.READABLE.is_writable())
    assert_true(Interest.WRITABLE.is_writable())
    assert_false(Interest.WRITABLE.is_readable())

    var both = Interest.READABLE | Interest.WRITABLE
    assert_true(both.is_readable())
    assert_true(both.is_writable())

    var empty = Interest()
    assert_false(empty.is_readable())
    assert_false(empty.is_writable())
    assert_false(empty.is_edge_triggered())
    assert_false(empty.is_oneshot())

    # Edge-triggered + oneshot round trip — required for HTTP/2/3 fanout.
    var i = Interest.READABLE | Interest.EDGE_TRIGGERED | Interest.ONESHOT
    assert_true(i.is_readable())
    assert_true(i.is_edge_triggered())
    assert_true(i.is_oneshot())
    assert_false(i.is_writable())

    # Standalone modifier flags should not look like readable/writable.
    assert_true(Interest.EDGE_TRIGGERED.is_edge_triggered())
    assert_false(Interest.EDGE_TRIGGERED.is_readable())
    assert_false(Interest.EDGE_TRIGGERED.is_writable())
    assert_true(Interest.ONESHOT.is_oneshot())
    assert_false(Interest.ONESHOT.is_readable())
    assert_false(Interest.ONESHOT.is_writable())


def main() raises:
    test_interest()
    print("PASS: test_interest.mojo")
