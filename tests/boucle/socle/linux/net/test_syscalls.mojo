from std.ffi import external_call
from std.testing import assert_true

from boucle.socle.linux.net.syscalls import _socket, _bind, _listen
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.options import AddrFamily, SocketType, SocketFlags, Protocol, Backlog


def test_syscalls() raises:
    # Create a TCP socket directly via raw syscall
    var tcp = _socket(
        Int32(AddrFamily.INET.id),
        SocketType.STREAM.id,
        Int32(Protocol.TCP.id),
    )
    assert_true(tcp > -1)

    # Create a UDP socket
    var udp = _socket(
        Int32(AddrFamily.INET.id),
        SocketType.DGRAM.id,
        Int32(Protocol.UDP.id),
    )
    assert_true(udp > -1)

    # Create with flags
    var flags = SocketFlags.NONBLOCK | SocketFlags.CLOEXEC
    var tcp_nb = _socket(
        Int32(AddrFamily.INET.id),
        SocketType.STREAM.id | Int32(flags.value),
        Int32(Protocol.TCP.id),
    )
    assert_true(tcp_nb > -1)

    # Bind to localhost:0 (OS picks port)
    var addr = SocketAddrV4(127, 0, 0, 1, port=0)
    var stor = addr.addr_stor()
    _bind(tcp_nb, stor.addr_unsafe_ptr(), Int32(SocketAddrStorV4.ADDR_LEN))

    # Listen
    _listen(tcp_nb, Backlog.DEFAULT.value)

    # Clean up raw fds (no RAII here — these are plain Int32 values)
    _ = external_call["close", Int32](tcp)
    _ = external_call["close", Int32](udp)
    _ = external_call["close", Int32](tcp_nb)


def main() raises:
    test_syscalls()
    print("PASS: test_syscalls.mojo")
