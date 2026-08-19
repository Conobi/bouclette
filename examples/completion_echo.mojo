"""Completion-model echo: TCP accept + connect, then send + recv.

Demonstrates the WatchLoop API end-to-end:
  1. Bind a listening TCP socket, discover the ephemeral port.
  2. Submit async accept + connect, run() to completion.
  3. Submit async send + recv, run() again.
  4. Verify byte counts match.

WatchLoop wraps io_uring behind asyncio-style Futures.
Submit operations, call run(), extract results.

Run:
    uv run -- mojo run -I . -D ASSERT=all examples/completion_echo.mojo
"""

from boucle.watch import WatchLoop
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from std.memory import Pointer
from std.testing import assert_equal, assert_true


def main() raises:
    # Server: bind to loopback, OS-assigned port.
    var server = Socket.tcp_v4()
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)

    # Extract the kernel-assigned port (big-endian → host order).
    var bound = server.local_addr_v4()
    var be = bound.addr.sin_port
    var port = ((be << 8) | (be >> 8)) & UInt16(0xFFFF)

    # Client socket.
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)

    # Phase 1: async accept + connect.
    var loop = WatchLoop(sq_entries=8)
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, target)
    loop.run()

    assert_true(connect_f.result().is_connected())
    var accepted = accept_f.result()

    # Phase 2: send "ping" from client, recv on accepted socket.
    var msg = String("ping")
    var recv_buf = InlineArray[UInt8, 16](fill=UInt8(0))
    var recv_span = Span[UInt8, MutAnyOrigin](
        unsafe_ptr=Pointer[UInt8, MutAnyOrigin](
            unsafe_from_address=Int(Pointer(to=recv_buf))
        ),
        length=16,
    )
    var send_f = loop.send(client, msg.as_bytes())
    var recv_f = loop.recv(accepted, recv_span)
    loop.run()

    assert_equal(send_f.result(), 4)
    assert_equal(recv_f.result(), 4)

    accepted.close()
    client.close()
    server.close()
    print("OK")
