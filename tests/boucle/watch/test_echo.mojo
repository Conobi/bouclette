"""Integration echo test for the full WatchLoop API.

Demonstrates end-to-end usage: TCP server setup, async accept + connect,
then async send + recv with content verification.

Phase 1: submit accept and connect as async ops, run() to completion.
Phase 2: send "ping" from client, recv on accepted socket, run() again.
Verify byte counts and buffer content.
"""

from std.testing import assert_equal, assert_true

from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.net.socket import Socket
from boucle.watch import (
    WatchLoop,
    AcceptFuture,
    ConnectFuture,
    RecvFuture,
    SendFuture,
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


def test_echo() raises:
    """Full echo test: connect, accept, send, recv with content check."""
    # -- Server setup --
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port
    assert_true(Int(port) > 0, "ephemeral port should be > 0")

    var client = Socket.tcp_v4()
    var target_addr = SocketAddrV4(127, 0, 0, 1, port=port)
    var loop = WatchLoop(capacity=8)

    # -- Phase 1: async accept + connect --
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, target_addr)
    loop.run()

    assert_true(connect_f.done(), "connect should be done after run()")
    assert_true(accept_f.done(), "accept should be done after run()")

    var outcome = connect_f.result()
    assert_true(outcome.is_connected(), "outcome should be CONNECTED")

    var accepted = accept_f.result()
    assert_true(accepted.raw() >= 0, "accepted fd should be valid")

    # -- Phase 2: send "ping" from client, recv on accepted socket --
    var msg = String("ping")
    var send_buf = List[UInt8]()
    for c in msg.as_bytes():
        send_buf.append(c)
    var send_f = loop.send(client, send_buf^)
    var recv_f = loop.recv(accepted, List[UInt8](length=64, fill=0))

    loop.run()

    assert_true(send_f.done(), "send should be done after run()")
    assert_true(recv_f.done(), "recv should be done after run()")

    var sent = send_f^.result()
    var received = recv_f^.result()
    assert_equal(sent.count, 4, "should have sent 4 bytes")
    assert_equal(received.count, 4, "should have received 4 bytes")

    # Verify buffer content matches "ping".
    assert_equal(
        String(from_utf8=received.transferred()),
        msg,
        "received bytes should equal the sent message",
    )

    # -- Cleanup --
    accepted.close()
    client.close()
    server.close()


def main() raises:
    test_echo()
    print("Echo test passed.")
