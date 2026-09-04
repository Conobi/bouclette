from boucle.readiness_state import Readiness
from std.testing import assert_true, assert_false


def test_readiness_state() raises:
    var r = Readiness(Readiness.READABLE)
    assert_true(r.is_readable())
    assert_false(r.is_writable())
    assert_false(r.is_error())
    assert_false(r.is_hup())

    var w = Readiness(Readiness.WRITABLE)
    assert_false(w.is_readable())
    assert_true(w.is_writable())

    var e = Readiness(Readiness.ERROR)
    assert_true(e.is_error())

    var h = Readiness(Readiness.HUP)
    assert_true(h.is_hup())

    var rh = Readiness(Readiness.READ_HUP)
    assert_true(rh.is_read_hup())

    var rw = Readiness(Readiness.READABLE | Readiness.WRITABLE)
    assert_true(rw.is_readable())
    assert_true(rw.is_writable())


def main() raises:
    test_readiness_state()
    print("PASS: test_readiness_state.mojo")
