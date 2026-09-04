"""Test ConnectFuture and WatchLoop.connect().

Creates a TCP loopback listener, submits both an async accept and an
async connect via WatchLoop, then verifies the connect outcome is
CONNECTED and the accept produces a valid socket.
"""

from std.testing import assert_true

from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.net.socket import Socket
from boucle.watch import WatchLoop, ConnectFuture, AcceptFuture, ConnectOutcome


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


def test_connect_basic() raises:
    """WatchLoop.connect() produces a CONNECTED outcome.

    Both connect and accept are submitted as async operations so they
    complete each other without needing blocking I/O or threads.
    """
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port
    assert_true(Int(port) > 0, "ephemeral port should be > 0")

    var client = Socket.tcp_v4()
    var target_addr = SocketAddrV4(127, 0, 0, 1, port=port)

    # Submit both connect and accept as async operations.
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

    accepted.close()
    client.close()
    server.close()


def main() raises:
    test_connect_basic()
    print("ConnectFuture tests passed.")
