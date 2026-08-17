"""Completion-model echo example: loopback TCP send/recv.

Demonstrates the CompletionLoop API end-to-end:
  1. Bind a listening TCP socket on 127.0.0.1:0 (OS-assigned port).
  2. Submit accept on the server.
  3. Submit connect on a client socket.
  4. Drive the loop until both complete; capture the accepted fd.
  5. Submit send on the client and recv on the accepted side.
  6. Drive the loop until both complete; assert bytes_received == bytes_sent.

The handler is a tiny state machine over CQE tokens — io_uring delivers
out-of-order completions, so we route by token rather than ordering.

Run:
    uv run -- mojo run -I . -D ASSERT=all examples/completion_echo.mojo
"""

from boucle.completion import _LegacyCompletionLoop as CompletionLoop, _LegacyCompletionHandler as CompletionHandler
from boucle.handle import RawHandle
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.options import Backlog
from boucle.socle.linux.raw import sockaddr_in
from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import assert_equal, assert_true


comptime _TOK_ACCEPT: UInt64 = 1
comptime _TOK_CONNECT: UInt64 = 2
comptime _TOK_SEND: UInt64 = 3
comptime _TOK_RECV: UInt64 = 4

comptime _MSG: StaticString = "ping"
comptime _MSG_LEN: Int = 4


struct EchoTracker(CompletionHandler):
    """Tracks the four completions and stashes the accepted fd."""

    var accepted_fd: Int32
    var connect_result: Int32
    var bytes_sent: Int32
    var bytes_recvd: Int32
    var accept_done: Bool
    var connect_done: Bool
    var send_done: Bool
    var recv_done: Bool

    def __init__(out self):
        self.accepted_fd = -1
        self.connect_result = 0
        self.bytes_sent = 0
        self.bytes_recvd = 0
        self.accept_done = False
        self.connect_done = False
        self.send_done = False
        self.recv_done = False

    def __init__(out self, *, deinit take: Self):
        self.accepted_fd = take.accepted_fd
        self.connect_result = take.connect_result
        self.bytes_sent = take.bytes_sent
        self.bytes_recvd = take.bytes_recvd
        self.accept_done = take.accept_done
        self.connect_done = take.connect_done
        self.send_done = take.send_done
        self.recv_done = take.recv_done

    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        if token == _TOK_ACCEPT:
            self.accepted_fd = result
            self.accept_done = True
        elif token == _TOK_CONNECT:
            self.connect_result = result
            self.connect_done = True
        elif token == _TOK_SEND:
            self.bytes_sent = result
            self.send_done = True
        elif token == _TOK_RECV:
            self.bytes_recvd = result
            self.recv_done = True


def main() raises:
    # ── Listening socket on loopback, ephemeral port ─────────────────────
    var server = Socket.tcp_v4()
    var bind_addr = SocketAddrV4(127, 0, 0, 1, port=0)
    server.bind(bind_addr)
    server.listen(Backlog.DEFAULT)

    # Discover the kernel-assigned port via getsockname(2).
    var bound = sockaddr_in()
    var bound_len = Int32(16)  # sizeof(sockaddr_in)
    var gs = external_call["getsockname", Int32](
        server.raw(),
        UnsafePointer(to=bound).bitcast[Int8](),
        UnsafePointer(to=bound_len).bitcast[Int8](),
    )
    if Int(gs) != 0:
        raise "getsockname failed"

    var be_port: UInt16 = bound.sin_port
    var host_port: UInt16 = (
        (be_port << 8) | (be_port >> 8)
    ) & UInt16(0xFFFF)
    assert_true(host_port != 0)

    # ── Submit accept + connect, drive the loop ──────────────────────────
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=host_port)
    var target_stor = target.addr_stor()
    var addr_ptr = target_stor.addr_unsafe_ptr()
    var addr_len: UInt64 = UInt64(SocketAddrStorV4.ADDR_LEN)

    var loop = CompletionLoop(EchoTracker(), sq_entries=8)
    loop.submit_accept(server.raw(), token=_TOK_ACCEPT)
    loop.submit_connect(client.raw(), addr_ptr, addr_len, token=_TOK_CONNECT)
    loop.run()

    assert_true(loop._handler.accept_done)
    assert_true(loop._handler.connect_done)
    assert_true(loop._handler.accepted_fd >= 0)
    assert_true(loop._handler.connect_result >= 0)

    var accepted_fd: RawHandle = loop._handler.accepted_fd

    # ── Send a small literal payload, recv on the accepted side ──────────
    var send_buf = UnsafePointer[Int8, StaticConstantOrigin](
        unsafe_from_address=Int(_MSG.unsafe_ptr())
    )
    var recv_buf = List[UInt8](length=16, fill=0)
    var recv_ptr = UnsafePointer[Int8, StaticConstantOrigin](
        unsafe_from_address=Int(recv_buf.unsafe_ptr())
    )

    loop.submit_send(client.raw(), send_buf, UInt(_MSG_LEN), token=_TOK_SEND)
    loop.submit_recv(accepted_fd, recv_ptr, UInt(16), token=_TOK_RECV)
    loop.run()

    assert_true(loop._handler.send_done)
    assert_true(loop._handler.recv_done)
    assert_equal(loop._handler.bytes_sent, Int32(_MSG_LEN))
    assert_equal(loop._handler.bytes_recvd, Int32(_MSG_LEN))

    # Verify byte content.
    for i in range(_MSG_LEN):
        assert_equal(Int(recv_buf[i]), Int(_MSG.unsafe_ptr()[i]))

    # Close the accepted fd; the Socket destructors handle client/server.
    _ = external_call["close", Int32](accepted_fd)
    _ = target_stor
    _ = client^
    _ = server^

    print("OK")
