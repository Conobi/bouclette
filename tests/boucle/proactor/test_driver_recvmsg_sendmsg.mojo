"""Integration test: submit_recvmsg and submit_sendmsg via IoUringDriver."""

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc as _heap_alloc
from std.testing import assert_true

from boucle.socle.linux.raw import msghdr
from boucle.socle.linux.raw.ctypes import c_void
from boucle.proactor.completion import Completion
from boucle.drivers.io_uring import IoUringDriver

comptime AF_INET = 2
comptime SOCK_DGRAM = 2


struct ResultTracker:
    """Records callback invocations for recvmsg/sendmsg completions."""

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
        """Callback that records the completion result."""
        var self_ptr = Pointer[ResultTracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].flags = flags
        self_ptr[].fired = True


def test_driver_recvmsg_sendmsg() raises:
    """Run recvmsg/sendmsg integration test."""
    # --- 1. Create two UDP sockets ---
    var fd_a = external_call["socket", Int32](
        Int32(AF_INET), Int32(SOCK_DGRAM), Int32(0)
    )
    assert_true(Int(fd_a) >= 0, "socket(fd_a) failed")

    var fd_b = external_call["socket", Int32](
        Int32(AF_INET), Int32(SOCK_DGRAM), Int32(0)
    )
    assert_true(Int(fd_b) >= 0, "socket(fd_b) failed")

    # --- 2. Bind both to 127.0.0.1:0 (ephemeral) ---
    # sockaddr_in: sin_family(2) sin_port(2) sin_addr(4) pad(8) = 16 bytes
    var addr_a = Array[UInt8, 16](fill=0)
    addr_a[0] = AF_INET  # sin_family low byte
    addr_a[4] = 127      # sin_addr = 127.0.0.1
    addr_a[7] = 1

    var bind_a = external_call["bind", Int32](
        fd_a,
        Pointer(to=addr_a).unsafe_bitcast[c_void](),
        Int32(16),
    )
    assert_true(Int(bind_a) == 0, "bind(fd_a) failed")

    var addr_b = Array[UInt8, 16](fill=0)
    addr_b[0] = AF_INET
    addr_b[4] = 127
    addr_b[7] = 1

    var bind_b = external_call["bind", Int32](
        fd_b,
        Pointer(to=addr_b).unsafe_bitcast[c_void](),
        Int32(16),
    )
    assert_true(Int(bind_b) == 0, "bind(fd_b) failed")

    # --- 3. Discover sock_b's ephemeral port ---
    var bound_b = Array[UInt8, 16](fill=0)
    var addrlen_b = Int32(16)
    var gsn_res = external_call["getsockname", Int32](
        fd_b,
        Pointer(to=bound_b).unsafe_bitcast[c_void](),
        Pointer(to=addrlen_b).unsafe_bitcast[Int32](),
    )
    assert_true(Int(gsn_res) == 0, "getsockname failed")
    var port_hi = bound_b[2]
    var port_lo = bound_b[3]
    var port = Int(port_hi) << 8 | Int(port_lo)
    print("bound port=", port)
    assert_true(port > 0, "ephemeral port is 0")

    # --- 4. Set up driver ---
    var driver = IoUringDriver(sq_entries=16)

    # --- 5. Prepare sendmsg (all heap-allocated for io_uring safety) ---
    # msghdr layout on x86_64 (56 bytes):
    #   0: msg_name(8)  8: msg_namelen(4)  12: pad(4)
    #  16: msg_iov(8)  24: msg_iovlen(8)
    #  32: msg_control(8)  40: msg_controllen(8)
    #  48: msg_flags(4)  52: pad(4)
    # iovec layout (16 bytes): iov_base(8) iov_len(8)

    # Payload: "hi" (2 bytes)
    var send_payload = _heap_alloc[UInt8](2).as_unsafe_any_origin()
    send_payload[] = UInt8(104)        # 'h'
    send_payload.unsafe_offset(1)[] = UInt8(105)  # 'i'

    # iovec for send
    var send_iov = _heap_alloc[UInt8](16).as_unsafe_any_origin()
    for i in range(16):
        send_iov.unsafe_offset(i)[] = UInt8(0)
    # iov_base = send_payload address (little-endian u64 at offset 0)
    var sp_addr = Int(send_payload)
    for i in range(8):
        send_iov.unsafe_offset(i)[] = UInt8((sp_addr >> (i * 8)) & 0xFF)
    # iov_len = 2 (little-endian u64 at offset 8)
    send_iov.unsafe_offset(8)[] = UInt8(2)

    # Destination sockaddr_in for sock_b (16 bytes)
    var dest_addr = _heap_alloc[UInt8](16).as_unsafe_any_origin()
    for i in range(16):
        dest_addr.unsafe_offset(i)[] = UInt8(0)
    dest_addr[] = UInt8(AF_INET)
    dest_addr.unsafe_offset(2)[] = port_hi        # sin_port (network byte order)
    dest_addr.unsafe_offset(3)[] = port_lo
    dest_addr.unsafe_offset(4)[] = UInt8(127)     # sin_addr 127.0.0.1
    dest_addr.unsafe_offset(5)[] = UInt8(0)
    dest_addr.unsafe_offset(6)[] = UInt8(0)
    dest_addr.unsafe_offset(7)[] = UInt8(1)

    # msghdr for send (56 bytes)
    var send_mhdr = _heap_alloc[UInt8](56).as_unsafe_any_origin()
    for i in range(56):
        send_mhdr.unsafe_offset(i)[] = UInt8(0)
    # msg_name = dest_addr pointer (offset 0, 8 bytes LE)
    var da_addr = Int(dest_addr)
    for i in range(8):
        send_mhdr.unsafe_offset(i)[] = UInt8((da_addr >> (i * 8)) & 0xFF)
    # msg_namelen = 16 (offset 8, 4 bytes LE)
    send_mhdr.unsafe_offset(8)[] = UInt8(16)
    # msg_iov = send_iov pointer (offset 16, 8 bytes LE)
    var si_addr = Int(send_iov)
    for i in range(8):
        send_mhdr.unsafe_offset(16 + i)[] = UInt8((si_addr >> (i * 8)) & 0xFF)
    # msg_iovlen = 1 (offset 24, 8 bytes LE)
    send_mhdr.unsafe_offset(24)[] = UInt8(1)

    # --- 6. Prepare recvmsg (all heap-allocated) ---
    var recv_buf = _heap_alloc[UInt8](16).as_unsafe_any_origin()
    for i in range(16):
        recv_buf.unsafe_offset(i)[] = UInt8(0)

    # iovec for recv
    var recv_iov = _heap_alloc[UInt8](16).as_unsafe_any_origin()
    for i in range(16):
        recv_iov.unsafe_offset(i)[] = UInt8(0)
    var rb_addr = Int(recv_buf)
    for i in range(8):
        recv_iov.unsafe_offset(i)[] = UInt8((rb_addr >> (i * 8)) & 0xFF)
    # iov_len = 16
    recv_iov.unsafe_offset(8)[] = UInt8(16)

    # msghdr for recv (56 bytes)
    var recv_mhdr = _heap_alloc[UInt8](56).as_unsafe_any_origin()
    for i in range(56):
        recv_mhdr.unsafe_offset(i)[] = UInt8(0)
    # msg_iov = recv_iov pointer (offset 16)
    var ri_addr = Int(recv_iov)
    for i in range(8):
        recv_mhdr.unsafe_offset(16 + i)[] = UInt8((ri_addr >> (i * 8)) & 0xFF)
    # msg_iovlen = 1 (offset 24)
    recv_mhdr.unsafe_offset(24)[] = UInt8(1)

    # --- 7. Wire completions ---
    var send_tracker = ResultTracker()
    var send_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=send_tracker))
    )
    var send_cmp = Completion(
        invoke=ResultTracker.on_complete, context=send_ctx
    )
    var send_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=send_cmp))
    )

    var recv_tracker = ResultTracker()
    var recv_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=recv_tracker))
    )
    var recv_cmp = Completion(
        invoke=ResultTracker.on_complete, context=recv_ctx
    )
    var recv_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=recv_cmp))
    )

    # --- 8. Submit sendmsg then recvmsg ---
    var send_msg_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(send_mhdr)
    )
    var recv_msg_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(recv_mhdr)
    )

    driver.submit_sendmsg(fd_a, send_msg_ptr, send_cmp_ptr)
    driver.submit_recvmsg(fd_b, recv_msg_ptr, recv_cmp_ptr)
    print("submitted sendmsg + recvmsg")

    # --- 9. Tick until both fire ---
    var ticks = 0
    while not send_tracker.fired or not recv_tracker.fired:
        _ = driver.tick(wait=True)
        ticks += 1
        print(
            "tick", ticks,
            "send=", send_tracker.fired,
            "recv=", recv_tracker.fired,
        )
        if ticks > 100:
            raise "timed out waiting for completions"

    print(
        "send_result=", Int(send_tracker.result),
        "recv_result=", Int(recv_tracker.result),
    )

    # --- 10. Assertions ---
    assert_true(
        Int(send_tracker.result) == 2,
        "sendmsg should return 2, got " + String(Int(send_tracker.result)),
    )
    assert_true(
        Int(recv_tracker.result) == 2,
        "recvmsg should return 2, got " + String(Int(recv_tracker.result)),
    )
    assert_true(
        Int(recv_buf[]) == 104,
        "first byte should be 'h' (104), got " + String(Int(recv_buf[])),
    )

    # --- 11. Cleanup ---
    _ = external_call["close", Int32](fd_a)
    _ = external_call["close", Int32](fd_b)
    send_payload.unsafe_free()
    send_iov.unsafe_free()
    dest_addr.unsafe_free()
    send_mhdr.unsafe_free()
    recv_buf.unsafe_free()
    recv_iov.unsafe_free()
    recv_mhdr.unsafe_free()

    _ = send_cmp
    _ = recv_cmp


def main() raises:
    test_driver_recvmsg_sendmsg()
    print("PASS: test_driver_recvmsg_sendmsg.mojo")
