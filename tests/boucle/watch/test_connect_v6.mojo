"""Test WatchLoop.connect() over IPv6.

Creates a TCP listener on the IPv6 loopback ::1, submits both an async
accept and an async connect via WatchLoop, then verifies the connect
outcome is CONNECTED and the accepted socket sees ::1 as its peer.
"""

from std.testing import assert_equal, assert_true

from boucle.net.addr import SocketAddrV6
from boucle.net.options import Backlog
from boucle.net.socket import Socket
from boucle.watch import WatchLoop, ConnectFuture, AcceptFuture, ConnectOutcome


def _loopback_v6(port: UInt16) -> SocketAddrV6:
    """Return the IPv6 loopback address ::1 on the given port.

    Args:
        port: The port in host order.

    Returns:
        [::1]:port.
    """
    return SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=port)


def _make_tcp_listener_v6() raises -> Socket:
    """Create a TCP v6 listener on ::1 with an ephemeral port.

    Returns:
        A non-blocking, listening socket.
    """
    var server = Socket.tcp_v6()
    server.set_reuse_addr()
    server.bind(_loopback_v6(0))
    server.listen(Backlog.DEFAULT)
    return server^


def test_connect_v6_basic() raises:
    """WatchLoop.connect() to [::1] produces a CONNECTED outcome.

    Both connect and accept are submitted as async operations so they
    complete each other without needing blocking I/O or threads. The
    accepted socket's peer must be ::1, proving the sockaddr_in6 the
    loop handed to the kernel was complete.
    """
    var server = _make_tcp_listener_v6()
    var port = server.local_addr_v6().port
    assert_true(Int(port) > 0, "ephemeral port should be > 0")

    var client = Socket.tcp_v6()
    var target_addr = _loopback_v6(port)

    var loop = WatchLoop(capacity=8)
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, target_addr)

    loop.run()

    assert_true(connect_f.done(), "connect should be done after run()")
    assert_true(accept_f.done(), "accept should be done after run()")

    var outcome = connect_f.result()
    assert_true(outcome.is_connected(), "outcome should be CONNECTED")

    var accepted = accept_f.result()
    assert_true(accepted.raw() >= 0, "accepted fd should be valid")

    var peer = accepted.peer_addr_v6()
    for i in range(7):
        assert_equal(peer.segments()[i], UInt16(0), "peer must be ::1")
    assert_equal(peer.segments()[7], UInt16(1), "peer must be ::1")
    assert_equal(peer.port, client.local_addr_v6().port)

    accepted.close()
    client.close()
    server.close()


def main() raises:
    test_connect_v6_basic()
    print("ConnectFuture IPv6 tests passed.")
