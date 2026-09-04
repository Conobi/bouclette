"""Test ConnectWithTimeoutFuture and WatchLoop.connect_with_timeout().

Exercises the composite connect+timeout+cancel lifecycle:
- Connect succeeds before timeout fires.
- Connect refused (port nobody listens on).
- Timeout fires before connect completes (non-routable address).
"""

from std.testing import assert_true

from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.net.socket import Socket
from boucle.watch import (
    WatchLoop,
    AcceptFuture,
    ConnectWithTimeoutFuture,
    ConnectOutcome,
)


def _make_tcp_listener() raises -> Socket:
    """Create a TCP v4 listener on 127.0.0.1 with an ephemeral port.

    Returns:
        A non-blocking, listening socket.
    """
    var server = Socket.tcp_v4()
    server.set_reuse_addr()
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)
    return server^


def test_connect_with_timeout_success() raises:
    """Connect succeeds before timeout fires.

    Both connect and accept complete normally; the timeout is
    cancelled as part of the composite lifecycle.
    """
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port
    assert_true(Int(port) > 0, "ephemeral port should be > 0")

    var client = Socket.tcp_v4()
    var target_addr = SocketAddrV4(127, 0, 0, 1, port=port)

    var loop = WatchLoop(capacity=16)
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
    var client = Socket.tcp_v4()
    var target_addr = SocketAddrV4(127, 0, 0, 1, port=UInt16(1))

    var loop = WatchLoop(capacity=16)
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
    var client = Socket.tcp_v4()
    var target_addr = SocketAddrV4(192, 0, 2, 1, port=UInt16(80))

    var loop = WatchLoop(capacity=16)
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
