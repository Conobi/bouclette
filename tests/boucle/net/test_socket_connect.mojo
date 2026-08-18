from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_true, assert_equal

from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrV6, SocketAddrStorV4, SocketAddrStorV6
from boucle.net.options import Backlog


def _getsockname_port_v4(ref s: Socket) raises -> UInt16:
    var stor = SocketAddrStorV4()
    var stor_p = Pointer(to=stor)
    var len = UInt32(16)
    var len_p = Pointer(to=len)
    var res = external_call["getsockname", Int32](
        s.raw(), stor_p, len_p,
    )
    if res < 0:
        raise String("getsockname failed: ", Int(res))
    var be = stor.addr.sin_port
    return (UInt16(be) >> 8) | ((UInt16(be) & UInt16(0xFF)) << 8)


def _getsockname_port_v6(ref s: Socket) raises -> UInt16:
    var stor = SocketAddrStorV6()
    var stor_p = Pointer(to=stor)
    var len = UInt32(28)
    var len_p = Pointer(to=len)
    var res = external_call["getsockname", Int32](
        s.raw(), stor_p, len_p,
    )
    if res < 0:
        raise String("getsockname failed: ", Int(res))
    var be = stor.addr.sin6_port
    return (UInt16(be) >> 8) | ((UInt16(be) & UInt16(0xFF)) << 8)


def _accept_one(ref server: Socket) raises -> Int32:
    var stor = SocketAddrStorV4()
    var stor_p = Pointer(to=stor)
    var len = UInt32(16)
    var len_p = Pointer(to=len)
    for _ in range(1000):
        var res = external_call["accept4", Int32](
            server.raw(), stor_p, len_p, Int32(0),
        )
        if res >= 0:
            return res
    raise String("accept timed out")


def _send_byte(ref s: Socket, b: UInt8) raises -> Int64:
    var v = b
    var v_p = Pointer(to=v)
    return external_call["send", Int64](
        s.raw(), v_p, UInt64(1), Int32(0),
    )


def _recv_byte(fd: Int32) raises -> Int64:
    var rx = UInt8(0)
    var rx_p = Pointer(to=rx)
    return external_call["recv", Int64](
        fd, rx_p, UInt64(1), Int32(0),
    )


def test_socket_connect() raises:
    var server = Socket.tcp_v4()
    var bind_addr = SocketAddrV4(127, 0, 0, 1, port=0)
    server.bind(bind_addr)
    server.listen(Backlog.DEFAULT)
    var port = _getsockname_port_v4(server)
    assert_true(port != 0)

    var dest = SocketAddrV4(127, 0, 0, 1, port=port)
    var client = Socket.tcp_connect(dest)
    assert_true(client.raw() > -1)

    var peer_fd = _accept_one(server)
    assert_true(peer_fd > -1)

    var sent = _send_byte(client, UInt8(0x42))
    assert_equal(sent, 1)

    var recvd = Int64(-1)
    for _ in range(1000):
        recvd = _recv_byte(peer_fd)
        if recvd == 1:
            break
    assert_equal(recvd, 1)

    _ = external_call["close", Int32](peer_fd)

    # udp_connect: bind dual-stack v6 listener, connect via v4 to 127.0.0.1.
    var udp_server = Socket.udp_listener_v6(0)
    var udp_port = _getsockname_port_v6(udp_server)
    assert_true(udp_port != 0)

    var udp_dest = SocketAddrV4(127, 0, 0, 1, port=udp_port)
    var udp_client = Socket.udp_connect(udp_dest)
    assert_true(udp_client.raw() > -1)

    var udp_sent = _send_byte(udp_client, UInt8(0x37))
    assert_equal(udp_sent, 1)

    var udp_rx = UInt8(0)
    var udp_rx_p = Pointer(to=udp_rx)
    var udp_recvd = Int64(-1)
    for _ in range(1000):
        udp_recvd = external_call["recv", Int64](
            udp_server.raw(), udp_rx_p, UInt64(1), Int32(0),
        )
        if udp_recvd == 1:
            break
    assert_equal(udp_recvd, 1)
    assert_equal(udp_rx, UInt8(0x37))


def main() raises:
    test_socket_connect()
    print("PASS: test_socket_connect.mojo")
