"""Completion-model echo: TCP accept + connect, then send + recv.

Demonstrates the WatchLoop API end-to-end:
  1. Bind a listening TCP socket, discover the ephemeral port.
  2. Submit async accept + connect, run() to completion.
  3. Submit async send + recv, run() again.
  4. Verify byte counts match.

WatchLoop wraps the platform completion backend (io_uring when
available, epoll otherwise) behind asyncio-style Futures.
Submit operations, call run(), extract results.

send() and recv() take the buffer by value: it belongs to the loop until
the operation completes, and result() hands it back with the byte count.

Run:
    uv run -- mojo run -I . -D ASSERT=all examples/completion_echo.mojo
"""

from boucle.watch import WatchLoop
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from std.testing import assert_equal, assert_true


def main() raises:
    # Server: bind to loopback, OS-assigned port.
    var server = Socket.tcp_v4()
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)

    var port = server.local_addr_v4().port

    # Client socket.
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)

    # Phase 1: async accept + connect.
    var loop = WatchLoop(capacity=8)
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, target)
    loop.run()

    assert_true(connect_f.result().is_connected())
    var accepted = accept_f.result()

    # Phase 2: send "ping" from client, recv on accepted socket.
    # Each buffer is handed to the loop and comes back from result(),
    # so nothing else can touch it while the kernel does.
    var msg = String("ping")
    var out_buf = List[UInt8]()
    for c in msg.as_bytes():
        out_buf.append(c)
    var send_f = loop.send(client, out_buf^)
    var recv_f = loop.recv(accepted, List[UInt8](length=16, fill=0))
    loop.run()

    var sent = send_f^.result()
    var received = recv_f^.result()
    assert_equal(sent.count, 4)
    assert_equal(received.count, 4)
    assert_equal(String(from_utf8=received.transferred()), msg)

    accepted.close()
    client.close()
    server.close()
    print("OK")
