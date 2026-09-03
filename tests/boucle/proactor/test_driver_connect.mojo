"""Integration test: submit connect via completion driver (success + refused)."""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.proactor.completion import Completion
from boucle.drivers.probe import ProbeCompletionDriver
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.options import Backlog
from boucle.socle.linux.raw import sockaddr_in


struct ConnectTracker:
    """Records callback invocations for connect completions."""

    var result: Int
    var flags: UInt32
    var fired: Bool

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.result = 0
        self.flags = UInt32(0)
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the connect result."""
        var self_ptr = Pointer[ConnectTracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].flags = flags
        self_ptr[].fired = True


def test_driver_connect() raises:
    """Run connect integration tests."""
    # --- Test 1: Connect to open port (success) ---

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

    # Build connect target address.
    var target = SocketAddrV4(127, 0, 0, 1, port=host_port)
    var target_stor = target.addr_stor()
    var addr_ptr = target_stor.addr_unsafe_ptr()
    var addr_len = UInt64(SocketAddrStorV4.ADDR_LEN)

    # Set up driver and completion.
    var driver = ProbeCompletionDriver(sq_entries=16)
    var tracker = ConnectTracker()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var cmp = Completion(invoke=ConnectTracker.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    # Submit connect and tick until completion fires.
    var client = Socket.tcp_v4()
    driver.submit_connect(client.raw(), addr_ptr, addr_len, cmp_ptr)

    var ticks = 0
    while not tracker.fired:
        _ = driver.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for connect completion"

    assert_equal(Int(tracker.result), 0)

    # Keep resources alive past completion.
    _ = cmp
    _ = target_stor
    _ = client^
    _ = server^

    # --- Test 2: Connect to refused port (ECONNREFUSED) ---

    var tracker2 = ConnectTracker()
    var ctx2 = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker2))
    )
    var cmp2 = Completion(invoke=ConnectTracker.on_complete, context=ctx2)
    var cmp2_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp2))
    )

    # Connect to 127.0.0.1:1 — nothing should be listening there.
    var target2 = SocketAddrV4(127, 0, 0, 1, port=1)
    var target2_stor = target2.addr_stor()
    var addr2_ptr = target2_stor.addr_unsafe_ptr()
    var addr2_len = UInt64(SocketAddrStorV4.ADDR_LEN)

    var client2 = Socket.tcp_v4()
    driver.submit_connect(client2.raw(), addr2_ptr, addr2_len, cmp2_ptr)

    var ticks2 = 0
    while not tracker2.fired:
        _ = driver.tick(wait=True)
        ticks2 += 1
        if ticks2 > 100:
            raise "timed out waiting for connect-refused completion"

    assert_equal(Int(tracker2.result), -111)

    # Keep resources alive past completion.
    _ = cmp2
    _ = target2_stor
    _ = client2^


def main() raises:
    test_driver_connect()
    print("PASS: test_driver_connect.mojo")
