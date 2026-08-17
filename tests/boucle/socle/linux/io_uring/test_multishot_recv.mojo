"""Test multishot recv with provided buffers via IoUringDriver.

Exercises the SQE-based provide_buffers + multishot recv path:
1. Create TCP listener + connected pair on [::1]
2. Provide buffers via the driver
3. Submit multishot recv with buffer group selection
4. Send a payload from the client
5. Verify buffer selection, byte count, and payload content
"""

from boucle.drivers.io_uring import IoUringDriver
from boucle.proactor.completion import Completion
from boucle.socle.ptr import null_ptr
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.linux.raw import (
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    IORING_CQE_BUFFER_SHIFT,
)
from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc as _heap_alloc
from std.ffi import external_call
from std.testing import assert_equal, assert_true

comptime AF_INET6 = 10
comptime SOCK_STREAM = 1
comptime IPPROTO_IPV6 = 41
comptime IPV6_V6ONLY = 26


struct Tracker:
    """Records callback invocations for multishot recv completions."""

    var call_count: Int
    var tokens: InlineArray[Int32, 8]
    var flags_arr: InlineArray[UInt32, 8]

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.call_count = 0
        self.tokens = InlineArray[Int32, 8](fill=0)
        self.flags_arr = InlineArray[UInt32, 8](fill=0)

    @staticmethod
    def on_complete(
        ctx: UnsafePointer[NoneType, MutAnyOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback that records the completion result and flags."""
        var self_ptr = UnsafePointer[Tracker, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        print(
            "CQE[",
            self_ptr[].call_count,
            "]: result=",
            result,
            " flags=0x",
            hex(Int(flags)),
        )
        if self_ptr[].call_count < 8:
            self_ptr[].tokens[self_ptr[].call_count] = result
            self_ptr[].flags_arr[self_ptr[].call_count] = flags
        self_ptr[].call_count += 1


struct SimpleResult:
    """Records a single completion result."""

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
        var self_ptr = UnsafePointer[SimpleResult, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


def test_multishot_recv() raises:
    """Multishot recv with SQE-based provided buffers via IoUringDriver."""
    # --- 1. Create TCP listener on [::1]:0, ephemeral port ---
    var listen_fd = external_call["socket", Int32](
        Int32(AF_INET6), Int32(SOCK_STREAM), Int32(0)
    )
    print("listen_fd=", listen_fd)
    assert_true(Int(listen_fd) >= 0, "socket() failed")

    var optval = Int32(0)
    _ = external_call["setsockopt", Int32](
        listen_fd,
        Int32(IPPROTO_IPV6),
        Int32(IPV6_V6ONLY),
        UnsafePointer(to=optval).bitcast[c_void](),
        Int32(4),
    )

    # sockaddr_in6, ::1, port 0
    var addr = InlineArray[UInt8, 28](fill=0)
    addr[0] = UInt8(AF_INET6)
    addr[8 + 15] = UInt8(1)  # ::1
    var addr_ptr = UnsafePointer(to=addr).bitcast[c_void]()
    var bind_res = external_call["bind", Int32](
        listen_fd, addr_ptr, Int32(28)
    )
    assert_equal(Int(bind_res), 0)
    var listen_res = external_call["listen", Int32](
        listen_fd, Int32(1)
    )
    assert_equal(Int(listen_res), 0)

    # Read back the ephemeral port
    var bound_addr = InlineArray[UInt8, 28](fill=0)
    var addrlen = Int32(28)
    var getsock_res = external_call["getsockname", Int32](
        listen_fd,
        UnsafePointer(to=bound_addr).bitcast[c_void](),
        UnsafePointer(to=addrlen).bitcast[Int32](),
    )
    assert_equal(Int(getsock_res), 0)
    var port_hi = bound_addr[2]
    var port_lo = bound_addr[3]
    var port = Int(port_hi) << 8 | Int(port_lo)
    print("listening port=", port)

    # --- 2. Connect a client socket ---
    var client_fd = external_call["socket", Int32](
        Int32(AF_INET6), Int32(SOCK_STREAM), Int32(0)
    )
    assert_true(Int(client_fd) >= 0, "client socket failed")

    var dest = InlineArray[UInt8, 28](fill=0)
    dest[0] = UInt8(AF_INET6)
    dest[2] = port_hi
    dest[3] = port_lo
    dest[8 + 15] = UInt8(1)  # ::1
    var connect_res = external_call["connect", Int32](
        client_fd,
        UnsafePointer(to=dest).bitcast[c_void](),
        Int32(28),
    )
    assert_equal(Int(connect_res), 0)

    # --- 3. Accept on the listener (blocking) ---
    var server_fd = external_call["accept", Int32](
        listen_fd,
        null_ptr[c_void, StaticConstantOrigin](),
        null_ptr[Int32, StaticConstantOrigin](),
    )
    print("server_fd=", server_fd)
    assert_true(Int(server_fd) >= 0, "accept() failed")

    # --- 4. Allocate buffer pool: 4 x 1024 bytes ---
    comptime BUF_SIZE = 1024
    comptime BUF_COUNT = 4
    var pool = _heap_alloc[UInt8](BUF_SIZE * BUF_COUNT)
    for i in range(BUF_SIZE * BUF_COUNT):
        pool[i] = 0

    # --- 5. IoUringDriver + provide_buffers + submit_recv_multishot ---
    var driver = IoUringDriver()

    # Wire provide_buffers completion.
    var pb_slot = SimpleResult()
    var pb_ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=pb_slot))
    )
    var pb_cmp = Completion(invoke=SimpleResult.on_complete, context=pb_ctx)
    var pb_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=pb_cmp))
    )
    driver.provide_buffers(
        pool.as_unsafe_any_origin(),
        buf_size=BUF_SIZE,
        count=BUF_COUNT,
        group_id=UInt16(7),
        base_buf_id=UInt16(0),
        c=pb_cmp_ptr,
    )

    # Wire recv multishot completion.
    var tracker = Tracker()
    var tracker_ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=tracker))
    )
    var recv_cmp = Completion(
        invoke=Tracker.on_complete, context=tracker_ctx
    )
    var recv_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=recv_cmp))
    )
    driver.submit_recv_multishot(
        fd=server_fd, buf_group=UInt16(7), c=recv_cmp_ptr
    )

    # First tick: provide_buffers CQE (recv multishot is still armed)
    driver.tick(wait=True)
    assert_true(
        pb_slot.fired,
        "expected provide_buffers CQE",
    )
    assert_true(
        pb_slot.result >= 0,
        "provide_buffers failed: " + String(pb_slot.result),
    )

    # --- 6. Send a payload from the client side ---
    var msg = InlineArray[UInt8, 5](fill=0)
    msg[0] = UInt8(ord("h"))
    msg[1] = UInt8(ord("e"))
    msg[2] = UInt8(ord("l"))
    msg[3] = UInt8(ord("l"))
    msg[4] = UInt8(ord("o"))
    var send_res = external_call["send", Int64](
        client_fd,
        UnsafePointer(to=msg).bitcast[c_void](),
        UInt64(5),
        Int32(0),
    )
    assert_equal(Int(send_res), 5)

    # --- 7. Tick for the recv CQE ---
    while tracker.call_count < 1:
        driver.tick(wait=True)
    print("after recv tick: call_count=", tracker.call_count)

    var recv_result = tracker.tokens[0]
    var recv_flags = tracker.flags_arr[0]
    print(
        "recv CQE: result=",
        recv_result,
        " flags=0x",
        hex(Int(recv_flags)),
    )

    # IORING_CQE_F_BUFFER must be set
    assert_true(
        Int(recv_flags) & IORING_CQE_F_BUFFER != 0,
        "IORING_CQE_F_BUFFER not set in flags=0x" + hex(Int(recv_flags)),
    )

    # 5 bytes received
    assert_equal(Int(recv_result), 5)

    # Extract buffer ID
    var buf_id = (Int(recv_flags) >> IORING_CQE_BUFFER_SHIFT) & 0xFFFF
    print("buf_id=", buf_id)
    assert_true(buf_id < BUF_COUNT, "buf_id out of range: " + String(buf_id))

    # Payload at offset 0 of the chosen buffer (no recvmsg_out header)
    var buf_start = pool + buf_id * BUF_SIZE
    var p0 = buf_start[0]
    var p1 = buf_start[1]
    var p2 = buf_start[2]
    var p3 = buf_start[3]
    var p4 = buf_start[4]
    print(
        "payload: ",
        chr(Int(p0)),
        chr(Int(p1)),
        chr(Int(p2)),
        chr(Int(p3)),
        chr(Int(p4)),
    )
    assert_equal(Int(p0), ord("h"))
    assert_equal(Int(p1), ord("e"))
    assert_equal(Int(p2), ord("l"))
    assert_equal(Int(p3), ord("l"))
    assert_equal(Int(p4), ord("o"))

    # Cleanup
    _ = external_call["close", Int32](client_fd)
    _ = external_call["close", Int32](server_fd)
    _ = external_call["close", Int32](listen_fd)
    pool.free()
    _ = pb_cmp
    _ = recv_cmp
    print("test_multishot_recv PASSED")


def main() raises:
    test_multishot_recv()
