from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from std.testing import assert_true


def test_socket() raises:
    # TCP IPv4
    var tcp4 = Socket.tcp_v4()
    assert_true(tcp4.raw() > -1)

    # TCP IPv6
    var tcp6 = Socket.tcp_v6()
    assert_true(tcp6.raw() > -1)

    # UDP IPv4
    var udp4 = Socket.udp_v4()
    assert_true(udp4.raw() > -1)

    # UDP IPv6
    var udp6 = Socket.udp_v6()
    assert_true(udp6.raw() > -1)

    # Bind + listen workflow
    var server = Socket.tcp_v4()
    var addr = SocketAddrV4(127, 0, 0, 1, port=0)
    server.bind(addr)
    server.listen(Backlog.DEFAULT)


def main() raises:
    test_socket()
    print("PASS: test_socket.mojo")
