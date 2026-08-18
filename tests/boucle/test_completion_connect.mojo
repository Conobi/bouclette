"""Test submit_connect on CompletionLoop by connecting to a loopback
TCP listener and verifying the completion reports success.
"""

from boucle.completion import CompletionLoop
from boucle.proactor.completion import Completion
from boucle.handle import RawHandle
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.options import Backlog
from boucle.socle.linux.raw import sockaddr_in
from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true


struct ConnectResult:
    """Records a single connect completion."""

    var result: Int32
    var fired: Bool

    def __init__(out self):
        """Construct an unfired result."""
        self.result = Int32(0)
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutAnyOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback that records the connect result."""
        var self_ptr = Pointer[ConnectResult, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


def test_completion_connect() raises:
    # Create a listening TCP socket on a loopback ephemeral port.
    var server = Socket.tcp_v4()
    var bind_addr = SocketAddrV4(127, 0, 0, 1, port=0)
    server.bind(bind_addr)
    server.listen(Backlog.DEFAULT)

    # Discover the kernel-assigned port via getsockname(2).
    var bound = sockaddr_in()
    var bound_len = Int32(16)  # sizeof(sockaddr_in); socklen_t is 32-bit
    var bound_ptr = Pointer(to=bound).unsafe_bitcast[Int8]()
    var bound_len_ptr = Pointer(to=bound_len).unsafe_bitcast[Int8]()
    var gs = external_call["getsockname", Int32](
        server.raw(), bound_ptr, bound_len_ptr
    )
    if Int(gs) != 0:
        var en = external_call[
            "__errno_location", Pointer[Int32, MutAnyOrigin]
        ]()
        raise String("getsockname failed, errno=") + String(Int(en[]))

    # sin_port is big-endian; byte-swap into host order.
    var be_port: UInt16 = bound.sin_port
    var host_port: UInt16 = (
        (be_port << 8) | (be_port >> 8)
    ) & UInt16(0xFFFF)
    assert_true(host_port != 0)

    # Build the connect target; keep the storage alive on the stack until
    # after the completion fires so the kernel can still read from it.
    var target = SocketAddrV4(127, 0, 0, 1, port=host_port)
    var target_stor = target.addr_stor()
    var addr_ptr = target_stor.addr_unsafe_ptr()
    var addr_len: UInt64 = UInt64(SocketAddrStorV4.ADDR_LEN)

    # Create the client socket and submit the connect.
    var client = Socket.tcp_v4()
    var loop = CompletionLoop(sq_entries=8)

    # Wire completion callback.
    var slot = ConnectResult()
    var ctx = Pointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var cmp = Completion(invoke=ConnectResult.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    loop.submit_connect(client.raw(), addr_ptr, addr_len, cmp_ptr)
    loop.tick(wait=True)

    assert_true(slot.fired, "connect completion did not fire")
    # Success is result >= 0 for connect(2); nonblocking sockets through
    # io_uring should also complete with 0 once the handshake is done.
    assert_true(slot.result >= Int32(0))

    # Keep storage and sockets alive past the completion.
    _ = target_stor
    _ = cmp
    _ = client^
    _ = server^


def main() raises:
    test_completion_connect()
    print("PASS: test_completion_connect.mojo")
