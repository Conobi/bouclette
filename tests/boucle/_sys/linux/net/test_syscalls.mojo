from boucle._sys.linux.net.socket import socket, bind, listen
from boucle.net.addr import SocketAddrV4
from boucle.net.options import AddrFamily, SocketType, SocketFlags, Protocol, Backlog
from std.testing import assert_true


def test_syscalls() raises:
    # Create a TCP socket directly via _sys wrapper
    var tcp = socket(AddrFamily.INET, SocketType.STREAM, Protocol.TCP)
    assert_true(tcp.raw() > -1)

    # Create a UDP socket
    var udp = socket(AddrFamily.INET, SocketType.DGRAM, Protocol.UDP)
    assert_true(udp.raw() > -1)

    # Create with flags
    var tcp_nb = socket(
        AddrFamily.INET,
        SocketType.STREAM,
        SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
        Protocol.TCP,
    )
    assert_true(tcp_nb.raw() > -1)

    # Bind to localhost:0 (OS picks port)
    var addr = SocketAddrV4(127, 0, 0, 1, port=0)
    bind(tcp_nb, addr)

    # Listen
    listen(tcp_nb, Backlog.DEFAULT)


def main() raises:
    test_syscalls()
    print("PASS: test_syscalls.mojo")
