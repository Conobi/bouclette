"""Test ConnectWithTimeoutFuture and WatchLoop.connect_with_timeout().

Exercises the composite connect+timeout+cancel lifecycle:
- Connect succeeds before timeout fires.
- Connect refused (port nobody listens on).
- Timeout fires before connect completes (non-routable address).

Uses direct syscalls for socket setup due to a Mojo 1.0.0 compiler bug
affecting Socket.bind() through parametric inlining.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.sys.info import size_of
from std.testing import assert_true

from boucle.watch import (
    WatchLoop,
    AcceptFuture,
    ConnectWithTimeoutFuture,
    ConnectOutcome,
)
from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.socle.linux.raw import sockaddr_in, socklen_t
from boucle.socle.linux.errno import get_errno


def _make_tcp_listener() raises -> Socket:
    """Create a TCP v4 listener on 127.0.0.1:0 using direct syscalls."""
    var fd = external_call["socket", Int32](
        Int32(2),
        Int32(1 | 2048 | 524288),
        Int32(6),
    )
    if fd < 0:
        raise String("socket failed: errno ", Int(get_errno()))

    var one = Int32(1)
    var one_p = Pointer(to=one)
    _ = external_call["setsockopt", Int32](
        fd, Int32(1), Int32(2), one_p, UInt32(4)
    )

    var addr = sockaddr_in()
    addr.sin_family = UInt16(2)
    addr.sin_port = UInt16(0)
    addr.sin_addr_s_addr = UInt32(0x0100007F)
    var addr_p = Pointer(to=addr)
    var res = external_call["bind", Int32](
        fd, addr_p, UInt32(size_of[sockaddr_in]())
    )
    if res < 0:
        _ = external_call["close", Int32](fd)
        raise String("bind failed: errno ", Int(get_errno()))

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
    var be = addr.sin_port
    return ((be << 8) | (be >> 8)) & UInt16(0xFFFF)


def _make_client_socket() raises -> Socket:
    """Create a non-blocking TCP client socket."""
    var fd = external_call["socket", Int32](
        Int32(2),
        Int32(1 | 2048 | 524288),
        Int32(6),
    )
    if fd < 0:
        raise String("socket failed: errno ", Int(get_errno()))
    return Socket(OwnedHandle(raw=fd))


def test_connect_with_timeout_success() raises:
    """Connect succeeds before timeout fires.

    Both connect and accept complete normally; the timeout is
    cancelled as part of the composite lifecycle.
    """
    var server = _make_tcp_listener()
    var port = _get_port(server)
    assert_true(Int(port) > 0, "ephemeral port should be > 0")

    var client = _make_client_socket()
    var target_addr = SocketAddrV4(127, 0, 0, 1, port=port)

    var loop = WatchLoop(sq_entries=16)
    var accept_f = loop.accept(server)
    var connect_f = loop.connect_with_timeout(
        client, target_addr, timeout_ms=5000
    )

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


def test_connect_with_timeout_refused() raises:
    """Connect to a port with no listener is REFUSED.

    Port 1 on loopback almost certainly has no listener, so the
    kernel returns ECONNREFUSED before the timeout fires.
    """
    var client = _make_client_socket()
    var target_addr = SocketAddrV4(127, 0, 0, 1, port=UInt16(1))

    var loop = WatchLoop(sq_entries=16)
    var connect_f = loop.connect_with_timeout(
        client, target_addr, timeout_ms=5000
    )

    loop.run()

    assert_true(connect_f.done(), "connect should be done after run()")

    var outcome = connect_f.result()
    assert_true(outcome.is_refused(), "outcome should be REFUSED")

    client.close()


def test_connect_with_timeout_timeout() raises:
    """Timeout fires before connect completes.

    192.0.2.1 (TEST-NET-1, RFC 5737) is non-routable on most
    networks, so connect hangs indefinitely. The 100ms timeout
    should resolve the operation as TIMEOUT.
    """
    var client = _make_client_socket()
    var target_addr = SocketAddrV4(192, 0, 2, 1, port=UInt16(80))

    var loop = WatchLoop(sq_entries=16)
    var connect_f = loop.connect_with_timeout(
        client, target_addr, timeout_ms=100
    )

    loop.run()

    assert_true(connect_f.done(), "connect should be done after run()")

    var outcome = connect_f.result()
    # On some networks TEST-NET may route, causing NETWORK_UNREACHABLE
    # instead of TIMEOUT. Accept either as a valid "not connected" result.
    assert_true(
        outcome.is_timeout() or outcome.is_network_unreachable(),
        String(
            "outcome should be TIMEOUT or NETWORK_UNREACHABLE, got: ",
            outcome,
        ),
    )

    client.close()


def main() raises:
    test_connect_with_timeout_success()
    test_connect_with_timeout_refused()
    test_connect_with_timeout_timeout()
    print("ConnectWithTimeoutFuture tests passed.")
