"""Test AcceptFuture and WatchLoop.accept().

Creates a TCP loopback listener, connects a blocking client, then
uses WatchLoop to async-accept the connection and verifies the
accepted socket is valid.

Note: uses direct syscalls for server setup due to a Mojo 1.0.0
compiler bug affecting Socket.bind() through parametric inlining.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.sys.info import size_of
from std.testing import assert_true

from boucle.watch import WatchLoop, AcceptFuture
from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
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


def _make_blocking_client(port: UInt16) raises -> Socket:
    """Create a blocking TCP client connected to 127.0.0.1:port."""
    # socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, IPPROTO_TCP) — blocking
    var fd = external_call["socket", Int32](
        Int32(2), Int32(1 | 524288), Int32(6)
    )
    if fd < 0:
        raise String("socket failed: errno ", Int(get_errno()))

    var addr = sockaddr_in()
    addr.sin_family = UInt16(2)
    # Port to big-endian
    addr.sin_port = ((port << 8) | (port >> 8)) & UInt16(0xFFFF)
    addr.sin_addr_s_addr = UInt32(0x0100007F)
    var addr_p = Pointer(to=addr)
    var res = external_call["connect", Int32](
        fd, addr_p, UInt32(size_of[sockaddr_in]())
    )
    if res < 0:
        _ = external_call["close", Int32](fd)
        raise String("connect failed: errno ", Int(get_errno()))

    return Socket(OwnedHandle(raw=fd))


def test_accept_basic() raises:
    """WatchLoop.accept() produces a valid connected socket."""
    var server = _make_tcp_listener()
    var port = _get_port(server)
    assert_true(Int(port) > 0, "ephemeral port should be > 0")

    # Blocking connect establishes the connection before accept.
    var client = _make_blocking_client(port)

    # Async accept via WatchLoop.
    var loop = WatchLoop(sq_entries=8)
    var accept_f = loop.accept(server)
    loop.run()

    assert_true(accept_f.done(), "accept should be done after run()")
    var accepted = accept_f.result()
    assert_true(accepted.raw() >= 0, "accepted fd should be valid")

    accepted.close()
    client.close()
    server.close()


def test_accept_drop_without_result() raises:
    """Dropping AcceptFuture without calling result() closes the fd."""
    var server = _make_tcp_listener()
    var port = _get_port(server)

    var client = _make_blocking_client(port)

    var loop = WatchLoop(sq_entries=8)
    var accept_f = loop.accept(server)
    loop.run()

    assert_true(accept_f.done(), "accept should be done")
    # Deliberately do NOT call result() — drop accept_f.
    # The __deinit__ should close the accepted fd.
    _ = accept_f^

    client.close()
    server.close()


def main() raises:
    test_accept_basic()
    test_accept_drop_without_result()
    print("AcceptFuture tests passed.")
