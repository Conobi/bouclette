from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import assert_true, assert_equal

from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrStorV6
from boucle.socle.ptr import null_ptr
from boucle.socle.linux.raw import (
    SOL_SOCKET,
    SO_REUSEADDR,
    SO_REUSEPORT,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    EAGAIN,
)


comptime SOCK_NONBLOCK = Int32(2048)
comptime SOCK_CLOEXEC = Int32(524288)


def _getsockopt_int(ref s: Socket, level: Int32, optname: Int32) raises -> Int32:
    var val = Int32(-1)
    var optlen = UInt32(4)
    var v_p = UnsafePointer(to=val)
    var l_p = UnsafePointer(to=optlen)
    var res = external_call["getsockopt", Int32](
        s.raw(), level, optname, v_p, l_p,
    )
    if res < 0:
        raise String("getsockopt failed: ", Int(res))
    return val


def _getsockname_port(ref s: Socket) raises -> UInt16:
    # IPv6 sockaddr is 28 bytes; sin6_port is at offset 2 (network order).
    var stor = SocketAddrStorV6()
    var stor_p = UnsafePointer(to=stor)
    var len = UInt32(28)
    var len_p = UnsafePointer(to=len)
    var res = external_call["getsockname", Int32](
        s.raw(), stor_p, len_p,
    )
    if res < 0:
        raise String("getsockname failed: ", Int(res))
    var be = stor.addr.sin6_port
    return (UInt16(be) >> 8) | ((UInt16(be) & UInt16(0xFF)) << 8)


def _check_listener_opts(ref s: Socket) raises:
    assert_true(_getsockopt_int(s, Int32(SOL_SOCKET), Int32(SO_REUSEADDR)) != 0)
    assert_true(_getsockopt_int(s, Int32(SOL_SOCKET), Int32(SO_REUSEPORT)) != 0)
    assert_equal(_getsockopt_int(s, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY)), 0)


def _assert_in_listen_state(ref s: Socket) raises:
    # accept4 on a listening socket with no pending connection returns -1
    # with errno=EAGAIN. A non-LISTEN socket returns -1 with errno=EINVAL.
    var null_addr = null_ptr[Int8, StaticConstantOrigin]()
    var null_len = null_ptr[UInt32, StaticConstantOrigin]()
    var res = external_call["accept4", Int32](
        s.raw(), null_addr, null_len, SOCK_NONBLOCK | SOCK_CLOEXEC,
    )
    assert_equal(Int(res), -1)
    var en = external_call[
        "__errno_location", UnsafePointer[Int32, MutAnyOrigin]
    ]()
    assert_equal(Int(en[]), EAGAIN)


def test_socket_factories() raises:
    var tcp = Socket.tcp_listener_v6(0)
    assert_true(tcp.raw() > -1)
    _check_listener_opts(tcp)
    var tcp_port = _getsockname_port(tcp)
    assert_true(tcp_port != 0)
    _assert_in_listen_state(tcp)

    var udp = Socket.udp_listener_v6(0)
    assert_true(udp.raw() > -1)
    _check_listener_opts(udp)
    var udp_port = _getsockname_port(udp)
    assert_true(udp_port != 0)


def main() raises:
    test_socket_factories()
    print("PASS: test_socket_factories.mojo")
