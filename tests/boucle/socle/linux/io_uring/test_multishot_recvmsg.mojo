from boucle import _LegacyCompletionLoop as CompletionLoop, CompletionHandler
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
comptime SOCK_DGRAM = 2
comptime IPPROTO_IPV6 = 41
comptime IPV6_V6ONLY = 26


struct Tracker(CompletionHandler):
    var call_count: Int
    var tokens: InlineArray[UInt64, 8]
    var results: InlineArray[Int32, 8]
    var flags_arr: InlineArray[UInt32, 8]

    def __init__(out self):
        self.call_count = 0
        self.tokens = InlineArray[UInt64, 8](fill=0)
        self.results = InlineArray[Int32, 8](fill=0)
        self.flags_arr = InlineArray[UInt32, 8](fill=0)

    def __init__(out self, *, deinit take: Self):
        self.call_count = take.call_count
        self.tokens = take.tokens
        self.results = take.results
        self.flags_arr = take.flags_arr

    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        print(
            "CQE[",
            self.call_count,
            "]: token=",
            token,
            " result=",
            result,
            " flags=0x",
            hex(Int(flags)),
        )
        if self.call_count < 8:
            self.tokens[self.call_count] = token
            self.results[self.call_count] = result
            self.flags_arr[self.call_count] = flags
        self.call_count += 1


def test_multishot_recvmsg() raises:
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
        UnsafePointer(to=optval).bitcast[c_void](),
        Int32(4),
    )

    # Build sockaddr_in6: 28 bytes
    # Layout: sin6_family(2) sin6_port(2) sin6_flowinfo(4) sin6_addr(16) sin6_scope_id(4)
    var addr = InlineArray[UInt8, 28](fill=0)
    addr[0] = AF_INET6  # sin6_family low byte
    addr[1] = 0  # sin6_family high byte
    # sin6_port = 0 (ephemeral)
    # sin6_addr = ::1 -> byte 15 of addr field = 1, addr field starts at offset 8
    addr[8 + 15] = 1  # ::1

    var addr_ptr = UnsafePointer(to=addr).bitcast[c_void]()
    var bind_res = external_call["bind", Int32](
        fd, addr_ptr, Int32(28)
    )
    print("bind result=", bind_res)
    assert_equal(Int(bind_res), 0)

    # Get the ephemeral port via getsockname
    var bound_addr = InlineArray[UInt8, 28](fill=0)
    var addrlen = Int32(28)
    var getsock_res = external_call["getsockname", Int32](
        fd,
        UnsafePointer(to=bound_addr).bitcast[c_void](),
        UnsafePointer(to=addrlen).bitcast[Int32](),
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
        pool[i] = 0

    # --- 3. Create CompletionLoop ---
    var loop = CompletionLoop(Tracker())

    # --- 4. Provide buffers ---
    loop.provide_buffers(
        pool,
        buf_size=BUF_SIZE,
        count=BUF_COUNT,
        group_id=0,
        base_buf_id=0,
        token=100,
    )

    # --- 5. Build msghdr template ---
    # For multishot recvmsg with provided buffers, the kernel uses a
    # template msghdr. We need msg_namelen set so the kernel writes the
    # peer address into the provided buffer's header. msg_name itself
    # is ignored (kernel uses the provided buffer). msg_iov/msg_iovlen
    # are also ignored but some kernels require msg_iovlen >= 1.
    #
    # struct msghdr layout on x86_64 (56 bytes):
    #   offset  0: msg_name     (8 bytes, pointer)
    #   offset  8: msg_namelen  (4 bytes, u32)
    #   offset 12: pad          (4 bytes)
    #   offset 16: msg_iov      (8 bytes, pointer)
    #   offset 24: msg_iovlen   (8 bytes, size_t)
    #   offset 32: msg_control  (8 bytes, pointer)
    #   offset 40: msg_controllen (8 bytes, size_t)
    #   offset 48: msg_flags    (4 bytes, int)
    #   offset 52: pad          (4 bytes)
    var msghdr_mem = _heap_alloc[UInt8](56).as_unsafe_any_origin()
    for i in range(56):
        msghdr_mem[i] = 0
    # msg_namelen = 28 at offset 8
    msghdr_mem[8] = 28

    var msghdr_ptr = UnsafePointer[c_void, StaticConstantOrigin](
        unsafe_from_address=Int(msghdr_mem)
    )

    # --- 6. Submit multishot recvmsg ---
    loop.submit_recvmsg_multishot(
        fd=fd, msghdr_ptr=msghdr_ptr, buf_group=0, token=200
    )

    # --- 7. Poll to submit both SQEs and get provide_buffers CQE ---
    loop.poll(wait_nr=1)
    print("after first poll: call_count=", loop._handler.call_count)
    assert_true(loop._handler.call_count >= 1, "expected at least 1 CQE")
    # provide_buffers should succeed
    assert_equal(loop._handler.tokens[0], UInt64(100))
    assert_true(
        loop._handler.results[0] >= 0,
        "provide_buffers failed: " + String(loop._handler.results[0]),
    )

    # --- 8. Send a datagram to self ---
    # Build dest addr with the ephemeral port
    var dest_addr = InlineArray[UInt8, 28](fill=0)
    dest_addr[0] = AF_INET6
    dest_addr[2] = port_hi  # port in network byte order
    dest_addr[3] = port_lo
    dest_addr[8 + 15] = 1  # ::1

    var msg = InlineArray[UInt8, 5](fill=0)
    msg[0] = UInt8(ord("h"))
    msg[1] = UInt8(ord("e"))
    msg[2] = UInt8(ord("l"))
    msg[3] = UInt8(ord("l"))
    msg[4] = UInt8(ord("o"))

    var send_res = external_call["sendto", Int64](
        fd,
        UnsafePointer(to=msg).bitcast[c_void](),
        UInt64(5),
        Int32(0),
        UnsafePointer(to=dest_addr).bitcast[c_void](),
        Int32(28),
    )
    print("sendto result=", send_res)
    assert_true(Int(send_res) == 5, "sendto failed: " + String(send_res))

    # --- 9. Poll for the recvmsg CQE ---
    loop.poll(wait_nr=1)
    print("after second poll: call_count=", loop._handler.call_count)

    # Find the recvmsg CQE (token=200)
    var recv_idx = -1
    for i in range(loop._handler.call_count):
        if loop._handler.tokens[i] == 200:
            recv_idx = i
            break
    assert_true(recv_idx >= 0, "no CQE with token=200 found")

    var recv_result = loop._handler.results[recv_idx]
    var recv_flags = loop._handler.flags_arr[recv_idx]
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

    # Read io_uring_recvmsg_out header from pool + buf_id * BUF_SIZE
    # struct io_uring_recvmsg_out {
    #   __u32 namelen;      // offset 0
    #   __u32 controllen;   // offset 4
    #   __u32 payloadlen;   // offset 8
    #   __u32 flags;        // offset 12
    # };
    var buf_start = pool + buf_id * BUF_SIZE
    var namelen = (
        Int(buf_start[0])
        | (Int(buf_start[1]) << 8)
        | (Int(buf_start[2]) << 16)
        | (Int(buf_start[3]) << 24)
    )
    var controllen = (
        Int(buf_start[4])
        | (Int(buf_start[5]) << 8)
        | (Int(buf_start[6]) << 16)
        | (Int(buf_start[7]) << 24)
    )
    var payloadlen = (
        Int(buf_start[8])
        | (Int(buf_start[9]) << 8)
        | (Int(buf_start[10]) << 16)
        | (Int(buf_start[11]) << 24)
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
    var p0 = buf_start[payload_offset]
    var p1 = buf_start[payload_offset + 1]
    var p2 = buf_start[payload_offset + 2]
    var p3 = buf_start[payload_offset + 3]
    var p4 = buf_start[payload_offset + 4]
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
    pool.free()
    print("test_multishot_recvmsg PASSED")


def main() raises:
    test_multishot_recvmsg()
