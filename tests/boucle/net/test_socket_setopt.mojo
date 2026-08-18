from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import assert_equal, assert_true

from boucle.net.socket import Socket
from boucle._sys.linux.raw import (
    SOL_SOCKET,
    SO_REUSEADDR,
    SO_REUSEPORT,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
)


def _getsockopt_int(fd: Int32, level: Int32, optname: Int32) raises -> Int32:
    var val = Int32(-1)
    var optlen = UInt32(4)
    var v_p = UnsafePointer(to=val)
    var l_p = UnsafePointer(to=optlen)
    var res = external_call["getsockopt", Int32](
        fd, level, optname, v_p, l_p,
    )
    if res < 0:
        raise String("getsockopt failed: ", Int(res))
    return val


def _check(ref s: Socket, level: Int32, optname: Int32, expected_nonzero: Bool) raises:
    var v = _getsockopt_int(s.raw(), level, optname)
    if expected_nonzero:
        assert_true(v != 0)
    else:
        assert_equal(v, 0)


def test_socket_setopt() raises:
    var s = Socket.tcp_v6()

    _check(s, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), False)
    _check(s, Int32(SOL_SOCKET), Int32(SO_REUSEPORT), False)

    s.set_reuse_addr()
    _check(s, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), True)

    s.set_reuse_addr(False)
    _check(s, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), False)

    s.set_reuse_port()
    _check(s, Int32(SOL_SOCKET), Int32(SO_REUSEPORT), True)

    s.set_v6only(True)
    _check(s, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), True)

    s.set_v6only(False)
    _check(s, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), False)


def main() raises:
    test_socket_setopt()
    print("PASS: test_socket_setopt.mojo")
