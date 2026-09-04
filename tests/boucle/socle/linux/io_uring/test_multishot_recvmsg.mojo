"""Test multishot recvmsg with provided buffers via IoUringDriver.

Exercises the SQE-based provide_buffers + multishot recvmsg path on UDP:
1. Create UDP socket, bind to [::1]:0
2. Provide buffers via the driver
3. Submit multishot recvmsg with buffer group selection
4. Send a datagram to self
5. Verify buffer selection, io_uring_recvmsg_out header, and payload
"""

from boucle.drivers.io_uring import IoUringDriver
from boucle.proactor.completion import Completion
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.linux.raw import (
    msghdr,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    IORING_CQE_BUFFER_SHIFT,
)
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc as _heap_alloc
from std.ffi import external_call
from std.testing import assert_equal, assert_true

comptime AF_INET6 = 10


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var d = IoUringDriver(capacity=4)
        _ = d^
        return True
    except:
        return False
comptime SOCK_DGRAM = 2
comptime IPPROTO_IPV6 = 41
comptime IPV6_V6ONLY = 26


struct Tracker:
    """Records callback invocations for multishot recvmsg completions."""

    var call_count: Int
    var results: Array[Int, 8]
    var flags_arr: Array[UInt32, 8]

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.call_count = 0
        self.results = Array[Int, 8](fill=0)
        self.flags_arr = Array[UInt32, 8](fill=0)

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the completion result and flags."""
        var self_ptr = Pointer[Tracker, MutUntrackedOrigin](
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
            self_ptr[].results[self_ptr[].call_count] = result
            self_ptr[].flags_arr[self_ptr[].call_count] = flags
        self_ptr[].call_count += 1


struct SimpleResult:
    """Records a single completion result."""

    var result: Int
    var fired: Bool

    def __init__(out self):
        """Construct an unfired result."""
        self.result = 0
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the result."""
        var self_ptr = Pointer[SimpleResult, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


def test_multishot_recvmsg() raises:
    """Multishot recvmsg with SQE-based provided buffers via IoUringDriver."""
    # --- 1. Create UDP socket, bind to [::1]:0 ---
    var fd = external_call["socket", Int32](
        Int32(AF_INET6), Int32(SOCK_DGRAM), Int32(0)
    )
    print("socket fd=", fd)
    assert_true(Int(fd) >= 0, "socket() failed")

    # Disable IPV6_V6ONLY is not needed for ::1, but set it anyway
    var optval = Int32(0)
    _ = external_call["setsockopt", Int32](
        fd,
        Int32(IPPROTO_IPV6),
        Int32(IPV6_V6ONLY),
        Pointer(to=optval).unsafe_bitcast[c_void](),
        Int32(4),
    )

    # Build sockaddr_in6: 28 bytes
    var addr = Array[UInt8, 28](fill=0)
    addr[0] = AF_INET6
    addr[1] = 0
    addr[8 + 15] = 1  # ::1

    var addr_ptr = Pointer(to=addr).unsafe_bitcast[c_void]()
    var bind_res = external_call["bind", Int32](
        fd, addr_ptr, Int32(28)
    )
    print("bind result=", bind_res)
    assert_equal(Int(bind_res), 0)

    # Get the ephemeral port via getsockname
    var bound_addr = Array[UInt8, 28](fill=0)
    var addrlen = Int32(28)
    var getsock_res = external_call["getsockname", Int32](
        fd,
        Pointer(to=bound_addr).unsafe_bitcast[c_void](),
        Pointer(to=addrlen).unsafe_bitcast[Int32](),
    )
    assert_equal(Int(getsock_res), 0)
    var port_hi = bound_addr[2]
    var port_lo = bound_addr[3]
    var port = Int(port_hi) << 8 | Int(port_lo)
    print("bound port=", port)
    assert_true(port > 0, "ephemeral port is 0")

    # --- 2. Allocate buffer pool: 4 x 1600 bytes ---
    comptime BUF_SIZE = 1600
    comptime BUF_COUNT = 4
    var pool = _heap_alloc[UInt8](BUF_SIZE * BUF_COUNT)
    for i in range(BUF_SIZE * BUF_COUNT):
        pool[unsafe_offset=i] = 0

    # --- 3. Create IoUringDriver ---
    var driver = IoUringDriver()

    # --- 4. Provide buffers ---
    var pb_slot = SimpleResult()
    var pb_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=pb_slot))
    )
    var pb_cmp = Completion(invoke=SimpleResult.on_complete, context=pb_ctx)
    var pb_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=pb_cmp))
    )
    driver.provide_buffers(
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(pool)),
        buf_size=BUF_SIZE,
        count=BUF_COUNT,
        group_id=UInt16(0),
        base_buf_id=UInt16(0),
        c=pb_cmp_ptr,
    )

    # --- 5. Build msghdr template ---
    # For multishot recvmsg with provided buffers, the kernel uses a
    # template msghdr. msg_namelen = 28 for IPv6 peer address.
    var msghdr_mem = _heap_alloc[UInt8](56).as_unsafe_any_origin()
    for i in range(56):
        msghdr_mem[unsafe_offset=i] = 0
    # msg_namelen = 28 at offset 8
    msghdr_mem[unsafe_offset=8] = 28

    var msghdr_ptr = Pointer[msghdr, MutUntrackedOrigin](
        unsafe_from_address=Int(msghdr_mem)
    )

    # --- 6. Submit multishot recvmsg ---
    var tracker = Tracker()
    var tracker_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var recv_cmp = Completion(
        invoke=Tracker.on_complete, context=tracker_ctx
    )
    var recv_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=recv_cmp))
    )
    driver.multishot_recvmsg(
        fd=fd, msg=msghdr_ptr, buf_group=UInt16(0), c=recv_cmp_ptr
    )

    # --- 7. Tick to submit both SQEs and get provide_buffers CQE ---
    _ = driver.tick(wait=True)
    print("after first tick: pb_fired=", pb_slot.fired)
    assert_true(pb_slot.fired, "expected provide_buffers CQE")
    assert_true(
        pb_slot.result >= 0,
        "provide_buffers failed: " + String(pb_slot.result),
    )

    # --- 8. Send a datagram to self ---
    var dest_addr = Array[UInt8, 28](fill=0)
    dest_addr[0] = AF_INET6
    dest_addr[2] = port_hi
    dest_addr[3] = port_lo
    dest_addr[8 + 15] = 1  # ::1

    var msg = Array[UInt8, 5](fill=0)
    msg[0] = UInt8(ord("h"))
    msg[1] = UInt8(ord("e"))
    msg[2] = UInt8(ord("l"))
    msg[3] = UInt8(ord("l"))
    msg[4] = UInt8(ord("o"))

    var send_res = external_call["sendto", Int64](
        fd,
        Pointer(to=msg).unsafe_bitcast[c_void](),
        UInt64(5),
        Int32(0),
        Pointer(to=dest_addr).unsafe_bitcast[c_void](),
        Int32(28),
    )
    print("sendto result=", send_res)
    assert_true(Int(send_res) == 5, "sendto failed: " + String(send_res))

    # --- 9. Tick for the recvmsg CQE ---
    while tracker.call_count < 1:
        _ = driver.tick(wait=True)
    print("after second tick: call_count=", tracker.call_count)

    var recv_result = tracker.results[0]
    var recv_flags = tracker.flags_arr[0]
    print(
        "recvmsg CQE: result=",
        recv_result,
        " flags=0x",
        hex(Int(recv_flags)),
    )

    # --- 10. Assertions ---
    # Check IORING_CQE_F_BUFFER is set
    assert_true(
        Int(recv_flags) & IORING_CQE_F_BUFFER != 0,
        "IORING_CQE_F_BUFFER not set in flags=0x" + hex(Int(recv_flags)),
    )
    # Check IORING_CQE_F_MORE is set (multishot still active)
    assert_true(
        Int(recv_flags) & IORING_CQE_F_MORE != 0,
        "IORING_CQE_F_MORE not set in flags=0x" + hex(Int(recv_flags)),
    )

    # Extract buffer ID
    var buf_id = (Int(recv_flags) >> IORING_CQE_BUFFER_SHIFT) & 0xFFFF
    print("buf_id=", buf_id)

    # Read io_uring_recvmsg_out header from pool.unsafe_offset(buf_id * BUF_SIZE)
    var buf_start = pool.unsafe_offset(buf_id * BUF_SIZE)
    var namelen = (
        Int(buf_start[unsafe_offset=0])
        | (Int(buf_start[unsafe_offset=1]) << 8)
        | (Int(buf_start[unsafe_offset=2]) << 16)
        | (Int(buf_start[unsafe_offset=3]) << 24)
    )
    var controllen = (
        Int(buf_start[unsafe_offset=4])
        | (Int(buf_start[unsafe_offset=5]) << 8)
        | (Int(buf_start[unsafe_offset=6]) << 16)
        | (Int(buf_start[unsafe_offset=7]) << 24)
    )
    var payloadlen = (
        Int(buf_start[unsafe_offset=8])
        | (Int(buf_start[unsafe_offset=9]) << 8)
        | (Int(buf_start[unsafe_offset=10]) << 16)
        | (Int(buf_start[unsafe_offset=11]) << 24)
    )
    print(
        "recvmsg_out: namelen=",
        namelen,
        " controllen=",
        controllen,
        " payloadlen=",
        payloadlen,
    )
    assert_equal(payloadlen, 5)

    # Read payload after the header (16 bytes) + namelen + controllen
    var payload_offset = 16 + namelen + controllen
    print("payload_offset=", payload_offset)
    var p0 = buf_start[unsafe_offset=payload_offset]
    var p1 = buf_start[unsafe_offset=payload_offset + 1]
    var p2 = buf_start[unsafe_offset=payload_offset + 2]
    var p3 = buf_start[unsafe_offset=payload_offset + 3]
    var p4 = buf_start[unsafe_offset=payload_offset + 4]
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
    _ = external_call["close", Int32](fd)
    pool.unsafe_free()
    msghdr_mem.unsafe_free()
    _ = pb_cmp
    _ = recv_cmp
    print("test_multishot_recvmsg PASSED")


def main() raises:
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_multishot_recvmsg()
