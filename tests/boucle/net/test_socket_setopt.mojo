from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.socle.linux.raw import (
    SOL_SOCKET,
    SO_REUSEADDR,
    SO_REUSEPORT,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    SOL_IP,
    SOL_IPV6,
    IP_TOS,
    IP_RECVTOS,
    IPV6_TCLASS,
    IPV6_RECVTCLASS,
    EAFNOSUPPORT,
)


def _getsockopt_int(fd: Int32, level: Int32, optname: Int32) raises -> Int32:
    var val = Int32(-1)
    var optlen = UInt32(4)
    var v_p = Pointer(to=val)
    var l_p = Pointer(to=optlen)
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


def _read(ref s: Socket, level: Int32, optname: Int32) raises -> Int32:
    """Read an integer option, keeping `s` alive through the syscall.

    `s.raw()` returns a plain `Int32` fd untied to `s`'s origin, so an
    inline `_getsockopt_int(s.raw(), ...)` lets Mojo's ASAP destruction
    close the socket right after `.raw()` returns and before the syscall
    runs, if that expression is `s`'s last use. Routing through a `ref`
    parameter keeps `s` alive for the whole call, matching `_check` above.
    """
    return _getsockopt_int(s.raw(), level, optname)


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


def test_recv_tos_on_v4_sets_ip_recvtos() raises:
    """AF_INET: IP_RECVTOS on, then off."""
    var s = Socket.udp_v4()
    _check(s, Int32(SOL_IP), Int32(IP_RECVTOS), False)
    s.set_recv_tos()
    _check(s, Int32(SOL_IP), Int32(IP_RECVTOS), True)
    s.set_recv_tos(False)
    _check(s, Int32(SOL_IP), Int32(IP_RECVTOS), False)


def test_recv_tos_on_v6_sets_both_levels() raises:
    """AF_INET6: IPV6_RECVTCLASS and IP_RECVTOS, so mapped peers deliver a TOS too."""
    var s = Socket.udp_v6()
    _check(s, Int32(SOL_IPV6), Int32(IPV6_RECVTCLASS), False)
    _check(s, Int32(SOL_IP), Int32(IP_RECVTOS), False)
    s.set_recv_tos()
    _check(s, Int32(SOL_IPV6), Int32(IPV6_RECVTCLASS), True)
    _check(s, Int32(SOL_IP), Int32(IP_RECVTOS), True)
    s.set_recv_tos(False)
    _check(s, Int32(SOL_IPV6), Int32(IPV6_RECVTCLASS), False)
    _check(s, Int32(SOL_IP), Int32(IP_RECVTOS), False)


def test_set_tos_writes_the_byte() raises:
    """IP_TOS on v4; IPV6_TCLASS and IP_TOS on v6. 0xB8 has no ECN bits."""
    var s4 = Socket.udp_v4()
    s4.set_tos(0xB8)
    assert_equal(_read(s4, Int32(SOL_IP), Int32(IP_TOS)), Int32(0xB8))
    var s6 = Socket.udp_v6()
    s6.set_tos(0x28)
    assert_equal(_read(s6, Int32(SOL_IPV6), Int32(IPV6_TCLASS)), Int32(0x28))
    assert_equal(_read(s6, Int32(SOL_IP), Int32(IP_TOS)), Int32(0x28))


def test_tos_on_a_unix_socket_is_eafnosupport() raises:
    """Neither option applies to AF_UNIX; the setter says so before any syscall."""
    var fds = InlineArray[Int32, 2](fill=Int32(0))
    var fds_p = Pointer(to=fds)
    var res = external_call["socketpair", Int32](
        Int32(1), Int32(2 | 2048 | 524288), Int32(0), fds_p
    )
    assert_true(res == 0, "socketpair")
    var a = Socket(OwnedHandle(raw=fds[0]))
    var b = Socket(OwnedHandle(raw=fds[1]))
    var caught = False
    try:
        a.set_recv_tos()
    except e:
        caught = e.errno_value() == EAFNOSUPPORT
    assert_true(caught, "AF_UNIX: EAFNOSUPPORT")
    a.close()
    b.close()


def main() raises:
    test_socket_setopt()
    test_recv_tos_on_v4_sets_ip_recvtos()
    test_recv_tos_on_v6_sets_both_levels()
    test_set_tos_writes_the_byte()
    test_tos_on_a_unix_socket_is_eafnosupport()
    print("PASS: test_socket_setopt.mojo")
