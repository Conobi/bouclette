"""Completion-model echo example: loopback TCP send/recv.

Demonstrates the CompletionLoop API end-to-end:
  1. Bind a listening TCP socket on 127.0.0.1:0 (OS-assigned port).
  2. Submit accept on the server.
  3. Submit connect on a client socket.
  4. Drive the loop until both complete; capture the accepted fd.
  5. Submit send on the client and recv on the accepted side.
  6. Drive the loop until both complete; assert bytes_received == bytes_sent.

Each operation carries its own Completion callback. The callback
records the kernel result and sets a "fired" flag; the driver
routes by SQE user_data (the Completion pointer).

Run:
    uv run -- mojo run -I . -D ASSERT=all examples/completion_echo.mojo
"""

from boucle.completion import CompletionLoop
from boucle.proactor.completion import Completion
from boucle.handle import RawHandle
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.options import Backlog
from boucle.socle.linux.raw import sockaddr_in
from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import assert_equal, assert_true


comptime _MSG: StaticString = "ping"
comptime _MSG_LEN: Int = 4


struct Slot:
    """Records a single I/O completion result."""

    var result: Int32
    var fired: Bool

    def __init__(out self):
        """Construct an unfired result."""
        self.result = Int32(0)
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: UnsafePointer[NoneType, MutAnyOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback that records the result."""
        var self_ptr = UnsafePointer[Slot, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


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

    var loop = CompletionLoop(sq_entries=8)

    # Wire accept completion.
    var accept_slot = Slot()
    var accept_ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=accept_slot))
    )
    var accept_cmp = Completion(invoke=Slot.on_complete, context=accept_ctx)
    var accept_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=accept_cmp))
    )

    # Wire connect completion.
    var connect_slot = Slot()
    var connect_ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=connect_slot))
    )
    var connect_cmp = Completion(invoke=Slot.on_complete, context=connect_ctx)
    var connect_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=connect_cmp))
    )

    loop.submit_accept(server.raw(), accept_cmp_ptr)
    loop.submit_connect(client.raw(), addr_ptr, addr_len, connect_cmp_ptr)

    # Both operations fire on the first tick.
    loop.tick(wait=True)

    assert_true(accept_slot.fired, "accept did not fire")
    assert_true(connect_slot.fired, "connect did not fire")
    assert_true(accept_slot.result >= 0, "accept failed")
    assert_true(connect_slot.result >= 0, "connect failed")

    var accepted_fd: RawHandle = accept_slot.result

    # ── Send a small literal payload, recv on the accepted side ──────────

    # Wire send completion.
    var send_slot = Slot()
    var send_ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=send_slot))
    )
    var send_cmp = Completion(invoke=Slot.on_complete, context=send_ctx)
    var send_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=send_cmp))
    )

    # Wire recv completion.
    var recv_slot = Slot()
    var recv_ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=recv_slot))
    )
    var recv_cmp = Completion(invoke=Slot.on_complete, context=recv_ctx)
    var recv_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=recv_cmp))
    )

    var msg_ptr = UnsafePointer[UInt8, MutAnyOrigin](
        unsafe_from_address=Int(_MSG.unsafe_ptr())
    )
    var recv_buf = List[UInt8](length=16, fill=0)
    var recv_ptr = UnsafePointer[UInt8, MutAnyOrigin](
        unsafe_from_address=Int(recv_buf.unsafe_ptr())
    )

    loop.submit_send(client.raw(), msg_ptr, UInt32(_MSG_LEN), send_cmp_ptr)
    loop.submit_recv(accepted_fd, recv_ptr, UInt32(16), recv_cmp_ptr)
    loop.tick(wait=True)

    assert_true(send_slot.fired, "send did not fire")
    assert_true(recv_slot.fired, "recv did not fire")
    assert_equal(send_slot.result, Int32(_MSG_LEN))
    assert_equal(recv_slot.result, Int32(_MSG_LEN))

    # Verify byte content.
    for i in range(_MSG_LEN):
        assert_equal(Int(recv_buf[i]), Int(_MSG.unsafe_ptr()[i]))

    # Close the accepted fd; the Socket destructors handle client/server.
    _ = external_call["close", Int32](accepted_fd)
    _ = target_stor
    _ = accept_cmp
    _ = connect_cmp
    _ = send_cmp
    _ = recv_cmp
    _ = client^
    _ = server^

    print("OK")
