"""Test ConnectFuture and WatchLoop.connect().

Creates a TCP loopback listener, submits both an async accept and an
async connect via WatchLoop, then verifies the connect outcome is
CONNECTED and the accept produces a valid socket.

Note: uses direct syscalls for socket setup due to a Mojo 1.0.0
compiler bug affecting Socket.bind() through parametric inlining.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.sys.info import size_of
from std.testing import assert_true

from boucle.watch import WatchLoop, ConnectFuture, AcceptFuture, ConnectOutcome
from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.socle.linux.raw import sockaddr_in, socklen_t
from boucle.socle.linux.errno import get_errno


def _make_tcp_listener() raises -> Socket:
    """Create a TCP v4 listener on 127.0.0.1:0 using direct syscalls.

    Returns a non-blocking, listening socket bound to an ephemeral port.
    """
    # socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, IPPROTO_TCP)
    var fd = external_call["socket", Int32](
        Int32(2),  # AF_INET
        Int32(1 | 2048 | 524288),  # SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
        Int32(6),  # IPPROTO_TCP
    )
    if fd < 0:
        raise String("socket failed: errno ", Int(get_errno()))

    # setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
    var one = Int32(1)
    var one_p = Pointer(to=one)
    _ = external_call["setsockopt", Int32](
        fd, Int32(1), Int32(2), one_p, UInt32(4)
    )

    # bind(fd, {AF_INET, port=0, 127.0.0.1}, sizeof(sockaddr_in))
    var addr = sockaddr_in()
    addr.sin_family = UInt16(2)  # AF_INET
    addr.sin_port = UInt16(0)
    addr.sin_addr_s_addr = UInt32(0x0100007F)  # 127.0.0.1 LE
    var addr_p = Pointer(to=addr)
    var res = external_call["bind", Int32](
        fd, addr_p, UInt32(size_of[sockaddr_in]())
    )
    if res < 0:
        _ = external_call["close", Int32](fd)
        raise String("bind failed: errno ", Int(get_errno()))

    # listen(fd, 128)
    res = external_call["listen", Int32](fd, Int32(128))
    if res < 0:
        _ = external_call["close", Int32](fd)
        raise String("listen failed: errno ", Int(get_errno()))

    return Socket(OwnedHandle(raw=fd))


def _get_port(ref server: Socket) raises -> UInt16:
    """Get the ephemeral port assigned to a bound socket."""
    var addr = sockaddr_in()
    var addrlen = socklen_t(size_of[sockaddr_in]())
    var addr_p = Pointer(to=addr)
    var len_p = Pointer(to=addrlen)
    var fd = server.raw()
    var res = external_call["getsockname", Int32](fd, addr_p, len_p)
    if res < 0:
        raise String("getsockname failed: errno ", Int(get_errno()))
    # sin_port is big-endian; byte-swap to host order.
    var be = addr.sin_port
    return ((be << 8) | (be >> 8)) & UInt16(0xFFFF)


def test_connect_basic() raises:
    """WatchLoop.connect() produces a CONNECTED outcome.

    Both connect and accept are submitted as async operations so they
    complete each other without needing blocking I/O or threads.
    """
    var server = _make_tcp_listener()
    var port = _get_port(server)
    assert_true(Int(port) > 0, "ephemeral port should be > 0")

    # Create a non-blocking client socket.
    var client_fd = external_call["socket", Int32](
        Int32(2),  # AF_INET
        Int32(1 | 2048 | 524288),  # SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
        Int32(6),  # IPPROTO_TCP
    )
    if client_fd < 0:
        server.close()
        raise String("socket failed: errno ", Int(get_errno()))
    var client = Socket(OwnedHandle(raw=client_fd))

    var target_addr = SocketAddrV4(127, 0, 0, 1, port=port)

    # Submit both connect and accept as async operations.
    var loop = WatchLoop(sq_entries=8)
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, target_addr)

    loop.run()

    assert_true(connect_f.done(), "connect should be done after run()")
    assert_true(accept_f.done(), "accept should be done after run()")

    var outcome = connect_f.result()
    assert_true(outcome.is_connected(), "outcome should be CONNECTED")

    var accepted = accept_f.result()
    assert_true(accepted.raw() >= 0, "accepted fd should be valid")

    accepted.close()
    client.close()
    server.close()


def main() raises:
    test_connect_basic()
    print("ConnectFuture tests passed.")
