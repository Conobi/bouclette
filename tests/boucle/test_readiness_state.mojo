from boucle.readiness_state import Readiness
from std.testing import assert_true, assert_false


def test_readiness_state() raises:
    var r = Readiness(0x001)  # EPOLLIN
    assert_true(r.is_readable())
    assert_false(r.is_writable())
    assert_false(r.is_error())
    assert_false(r.is_hup())

    var w = Readiness(0x004)  # EPOLLOUT
    assert_false(w.is_readable())
    assert_true(w.is_writable())

    var e = Readiness(0x008)  # EPOLLERR
    assert_true(e.is_error())

    var h = Readiness(0x010)  # EPOLLHUP
    assert_true(h.is_hup())

    var rh = Readiness(0x2000)  # EPOLLRDHUP
    assert_true(rh.is_read_hup())

    var rw = Readiness(0x001 | 0x004)
    assert_true(rw.is_readable())
    assert_true(rw.is_writable())


def main() raises:
    test_readiness_state()
    print("PASS: test_readiness_state.mojo")
