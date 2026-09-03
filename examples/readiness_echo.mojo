"""Readiness-model echo: poll for readability, then recv.

Demonstrates the ReadinessLoop API with Socket:
  1. Set up a TCP connection on loopback (server accept + client connect).
  2. Register the accepted socket for READABLE events.
  3. Send a message from the client.
  4. Poll — the handler observes readability and reads the bytes.

In readiness-driven I/O, boucle tells you when I/O is possible.
You own the buffers and perform the actual read/write yourself.

Run:
    uv run -- mojo run -I . -D ASSERT=all examples/readiness_echo.mojo
"""

from boucle.readiness import ReadinessLoop, ReadinessHandler
from boucle.interest import Interest
from boucle.readiness_state import Readiness
from boucle.token import Token
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from std.memory import Pointer
from std.testing import assert_equal, assert_true


struct EchoHandler(ReadinessHandler):
    """Reads incoming bytes when the socket becomes readable."""

    var peer: Socket
    var got_event: Bool
    var bytes_read: Int
    var buf: InlineArray[UInt8, 64]

    def __init__(out self, var peer: Socket):
        """Construct a handler that reads from the accepted peer socket."""
        self.peer = peer^
        self.got_event = False
        self.bytes_read = 0
        self.buf = InlineArray[UInt8, 64](fill=0)

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.peer = move.peer^
        self.got_event = move.got_event
        self.bytes_read = move.bytes_read
        self.buf = move.buf^

    def on_ready(
        mut self,
        loop: Pointer[ReadinessLoop[Self], MutUntrackedOrigin],
        token: Token,
        readiness: Readiness,
    ):
        """Handle a readiness event by reading from the peer socket."""
        self.got_event = True
        if readiness.is_readable():
            var span = Span[UInt8, MutAnyOrigin](
                unsafe_ptr=Pointer[UInt8, MutAnyOrigin](
                    unsafe_from_address=Int(Pointer(to=self.buf))
                ),
                length=64,
            )
            try:
                self.bytes_read = self.peer.recv(span)
            except:
                pass


def main() raises:
    # Server: bind to loopback, OS-assigned port.
    var server = Socket.tcp_v4()
    server.set_blocking(True)
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)
    var port = server.local_addr_v4().port

    # Client: blocking connect to the server.
    var client = Socket.tcp_connect(SocketAddrV4(127, 0, 0, 1, port=port))

    # Accept the connection (blocking). The accepted socket is non-blocking.
    var peer = server.accept()
    var peer_fd = peer.raw()

    # Set up the readiness loop with the accepted socket.
    var loop = ReadinessLoop(EchoHandler(peer^), max_events=16)
    loop.register(peer_fd, Interest.READABLE, Token(1))

    # Send "hello" from the client side.
    var msg = String("hello")
    _ = client.send(msg.as_bytes())

    # Poll — handler fires on readability and reads the bytes.
    loop.poll(timeout_ms=1000)

    assert_true(loop._handler.got_event)
    assert_equal(loop._handler.bytes_read, 5)

    loop.deregister(peer_fd)
    client.close()
    server.close()
    print("OK")
