"""Integration test: submit accept via IoUringDriver."""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_true

from boucle.proactor.completion import Completion
from boucle.drivers.io_uring import IoUringDriver
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.options import Backlog
from boucle.socle.linux.raw import sockaddr_in


struct AcceptTracker:
    """Records callback invocations for accept completions."""

    var result: Int32
    var flags: UInt32
    var fired: Bool

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.result = Int32(0)
        self.flags = UInt32(0)
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback that records the accept result."""
        var self_ptr = Pointer[AcceptTracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].flags = flags
        self_ptr[].fired = True


def test_driver_accept() raises:
    """Run accept integration test."""
    # Create a listening TCP socket on loopback ephemeral port.
    var server = Socket.tcp_v4()
    var bind_addr = SocketAddrV4(127, 0, 0, 1, port=0)
    server.bind(bind_addr)
    server.listen(Backlog.DEFAULT)

    # Discover the kernel-assigned port via getsockname(2).
    var bound = sockaddr_in()
    var bound_len = Int32(16)
    var bound_ptr = Pointer(to=bound).unsafe_bitcast[Int8]()
    var bound_len_ptr = Pointer(to=bound_len).unsafe_bitcast[Int8]()
    var gs = external_call["getsockname", Int32](
        server.raw(), bound_ptr, bound_len_ptr
    )
    if Int(gs) != 0:
        var en = external_call[
            "__errno_location", Pointer[Int32, MutUntrackedOrigin]
        ]()
        raise String("getsockname failed, errno=") + String(Int(en[]))

    # sin_port is big-endian; byte-swap into host order.
    var be_port: UInt16 = bound.sin_port
    var host_port: UInt16 = ((be_port << 8) | (be_port >> 8)) & UInt16(0xFFFF)
    assert_true(host_port != 0)

    # Build connect target address for the client.
    var target = SocketAddrV4(127, 0, 0, 1, port=host_port)
    var target_stor = target.addr_stor()
    var addr_ptr = target_stor.addr_unsafe_ptr()
    var addr_len = UInt64(SocketAddrStorV4.ADDR_LEN)

    # Set up driver.
    var driver = IoUringDriver(sq_entries=16)

    # Set up accept completion.
    var accept_tracker = AcceptTracker()
    var accept_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=accept_tracker))
    )
    var accept_cmp = Completion(
        invoke=AcceptTracker.on_complete, context=accept_ctx
    )
    var accept_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=accept_cmp))
    )

    # Set up connect completion.
    var connect_tracker = AcceptTracker()
    var connect_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=connect_tracker))
    )
    var connect_cmp = Completion(
        invoke=AcceptTracker.on_complete, context=connect_ctx
    )
    var connect_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=connect_cmp))
    )

    # Submit accept on the server socket first, then connect from client.
    driver.submit_accept(server.raw(), accept_cmp_ptr)

    var client = Socket.tcp_v4()
    driver.submit_connect(client.raw(), addr_ptr, addr_len, connect_cmp_ptr)

    # Tick until both completions fire.
    var ticks = 0
    while not accept_tracker.fired or not connect_tracker.fired:
        driver.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for accept/connect completion"

    # The accept result should be the accepted FD (>= 0).
    assert_true(
        Int(accept_tracker.result) >= 0, "accepted FD should be >= 0"
    )

    # The connect result should be 0 (success).
    assert_true(
        Int(connect_tracker.result) == 0, "connect should succeed"
    )

    # Close the accepted FD.
    var accepted_fd = Int(accept_tracker.result)
    _ = external_call["close", Int32](Int32(accepted_fd))

    # Keep resources alive past completion.
    _ = target_stor
    _ = client^
    _ = server^


def main() raises:
    test_driver_accept()
    print("PASS: test_driver_accept.mojo")
