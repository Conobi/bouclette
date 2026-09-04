"""Test AcceptFuture and WatchLoop.accept().

Creates a TCP loopback listener, connects a blocking client, then
uses WatchLoop to async-accept the connection and verifies the
accepted socket is valid.
"""

from std.testing import assert_true

from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.net.socket import Socket
from boucle.watch import WatchLoop, AcceptFuture


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


def _make_blocking_client(port: UInt16) raises -> Socket:
    """Create a blocking TCP client connected to 127.0.0.1:port.

    Args:
        port: The listener's port, in host byte order.

    Returns:
        The connected client socket.
    """
    return Socket.tcp_connect(SocketAddrV4(127, 0, 0, 1, port=port))


def test_accept_basic() raises:
    """WatchLoop.accept() produces a valid connected socket."""
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port
    assert_true(Int(port) > 0, "ephemeral port should be > 0")

    # Blocking connect establishes the connection before accept.
    var client = _make_blocking_client(port)

    # Async accept via WatchLoop.
    var loop = WatchLoop(capacity=8)
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
    var port = server.local_addr_v4().port

    var client = _make_blocking_client(port)

    var loop = WatchLoop(capacity=8)
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
