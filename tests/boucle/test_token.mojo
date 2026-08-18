from boucle.token import Token
from std.testing import assert_true, assert_false, assert_equal


def test_token() raises:
    var t1 = Token(0)
    var t2 = Token(42)
    var t3 = Token(42)

    assert_false(t1 == t2)
    assert_true(t2 == t3)

    assert_true(t1 != t2)
    assert_false(t2 != t3)

    assert_equal(t1.value, UInt64(0))
    assert_equal(t2.value, UInt64(42))


def main() raises:
    test_token()
    print("PASS: test_token.mojo")
