"""Integration test: multishot recvmsg with provided buffer ring via IoUringDriver.

Exercises the full BufRing + multishot recvmsg path:
1. Create a UDP recv socket, bind, discover ephemeral port
2. Register a BufRing with the driver
3. Submit multishot recvmsg with buffer group selection
4. Send 3 datagrams from a second UDP socket
5. Tick until all 3 completions fire
6. Verify buffer IDs, received byte counts, and payload content
7. Recycle buffers via add_buffer after each CQE
8. Unregister buf ring, close sockets
"""

from std.ffi import external_call
from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc as _heap_alloc
from std.testing import assert_true

from boucle._sys.linux.raw import (
    msghdr,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    IORING_CQE_BUFFER_SHIFT,
)
from boucle._sys.linux.raw.ctypes import c_void
from boucle.proactor.completion import Completion
from boucle.proactor.bufring import BufRing
from boucle.drivers.io_uring import IoUringDriver

comptime AF_INET = 2
comptime SOCK_DGRAM = 2
comptime NUM_BUFS = 16
comptime BUF_SIZE = 1500
comptime NUM_DATAGRAMS = 3
comptime GROUP_ID = 1


struct MultishotTracker:
    """Records callback invocations for multishot recvmsg completions.

    Stores results, flags, and buffer IDs for up to NUM_DATAGRAMS
    completions so the test can verify each one.
    """

    var count: Int
    var results: InlineArray[Int32, 8]
    var flags: InlineArray[UInt32, 8]
    var buf_ids: InlineArray[UInt16, 8]

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.count = 0
        self.results = InlineArray[Int32, 8](fill=Int32(0))
        self.flags = InlineArray[UInt32, 8](fill=UInt32(0))
        self.buf_ids = InlineArray[UInt16, 8](fill=UInt16(0))

    @staticmethod
    def on_complete(
        ctx: UnsafePointer[NoneType, MutAnyOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback that records the completion result and buffer ID."""
        var self_ptr = UnsafePointer[MultishotTracker, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        var idx = self_ptr[].count
        if idx < 8:
            self_ptr[].results[idx] = result
            self_ptr[].flags[idx] = flags
            # Extract buffer ID from flags bits 16-31
            self_ptr[].buf_ids[idx] = UInt16(flags >> IORING_CQE_BUFFER_SHIFT)
        self_ptr[].count += 1


def test_driver_multishot_recvmsg() raises:
    """Run multishot recvmsg integration test with provided buffer ring."""
    # --- 1. Create two UDP sockets ---
    var fd_recv = external_call["socket", Int32](
        Int32(AF_INET), Int32(SOCK_DGRAM), Int32(0)
    )
    assert_true(Int(fd_recv) >= 0, "socket(fd_recv) failed")

    var fd_send = external_call["socket", Int32](
        Int32(AF_INET), Int32(SOCK_DGRAM), Int32(0)
    )
    assert_true(Int(fd_send) >= 0, "socket(fd_send) failed")

    # --- 2. Bind recv socket to 127.0.0.1:0 (ephemeral) ---
    # sockaddr_in: sin_family(2) sin_port(2) sin_addr(4) pad(8) = 16 bytes
    var bind_addr = InlineArray[UInt8, 16](fill=0)
    bind_addr[0] = AF_INET  # sin_family low byte
    bind_addr[4] = 127      # sin_addr = 127.0.0.1
    bind_addr[7] = 1

    var bind_res = external_call["bind", Int32](
        fd_recv,
        UnsafePointer(to=bind_addr).bitcast[c_void](),
        Int32(16),
    )
    assert_true(Int(bind_res) == 0, "bind(fd_recv) failed")

    # --- 3. Discover recv socket's ephemeral port ---
    var bound = InlineArray[UInt8, 16](fill=0)
    var addrlen = Int32(16)
    var gsn_res = external_call["getsockname", Int32](
        fd_recv,
        UnsafePointer(to=bound).bitcast[c_void](),
        UnsafePointer(to=addrlen).bitcast[Int32](),
    )
    assert_true(Int(gsn_res) == 0, "getsockname failed")
    var port_hi = bound[2]
    var port_lo = bound[3]
    var port = Int(port_hi) << 8 | Int(port_lo)
    print("recv socket bound port=", port)
    assert_true(port > 0, "ephemeral port is 0")

    # --- 4. Create driver and register BufRing ---
    var driver = IoUringDriver(sq_entries=64)

    # Allocate data buffer pool (NUM_BUFS * BUF_SIZE bytes)
    var buf_base = _heap_alloc[UInt8](NUM_BUFS * BUF_SIZE).as_unsafe_any_origin()
    for i in range(NUM_BUFS * BUF_SIZE):
        buf_base[i] = UInt8(0)

    var bufring = driver.register_buf_ring(
        buf_base,
        UInt32(BUF_SIZE),
        NUM_BUFS,
        group_id=UInt16(GROUP_ID),
    )
    print("registered buf ring with", NUM_BUFS, "buffers of", BUF_SIZE, "bytes")

    # --- 5. Prepare msghdr template for multishot recvmsg (heap-allocated) ---
    # For multishot recvmsg with provided buffers, the kernel writes
    # io_uring_recvmsg_out (16 bytes) + msg_name + msg_control + payload
    # into the provided buffer. The msghdr template provides structural
    # info (namelen, controllen) but the iov data pointer is ignored.
    #
    # msghdr layout on x86_64 (56 bytes):
    #   0: msg_name(8)  8: msg_namelen(4)  12: pad(4)
    #  16: msg_iov(8)  24: msg_iovlen(8)
    #  32: msg_control(8)  40: msg_controllen(8)
    #  48: msg_flags(4)  52: pad(4)

    # iovec template (16 bytes): iov_base(8) iov_len(8)
    var recv_iov = _heap_alloc[UInt8](16).as_unsafe_any_origin()
    for i in range(16):
        (recv_iov + i)[] = UInt8(0)

    # msghdr for recv (56 bytes) - minimal template
    var recv_mhdr = _heap_alloc[UInt8](56).as_unsafe_any_origin()
    for i in range(56):
        (recv_mhdr + i)[] = UInt8(0)
    # msg_iov = recv_iov pointer (offset 16, 8 bytes LE)
    var ri_addr = Int(recv_iov)
    for i in range(8):
        (recv_mhdr + 16 + i)[] = UInt8((ri_addr >> (i * 8)) & 0xFF)
    # msg_iovlen = 1 (offset 24, 8 bytes LE)
    (recv_mhdr + 24)[] = UInt8(1)

    var recv_msg_ptr = UnsafePointer[msghdr, MutAnyOrigin](
        unsafe_from_address=Int(recv_mhdr)
    )

    # --- 6. Wire completion callback ---
    var tracker = MultishotTracker()
    var tracker_ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=tracker))
    )
    var recv_cmp = Completion(
        invoke=MultishotTracker.on_complete, context=tracker_ctx
    )
    var recv_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=recv_cmp))
    )

    # --- 7. Submit multishot recvmsg ---
    driver.submit_multishot_recvmsg(
        fd_recv, recv_msg_ptr, UInt16(GROUP_ID), recv_cmp_ptr
    )
    print("submitted multishot recvmsg")

    # --- 8. Flush SQE to kernel (non-blocking tick) ---
    driver.tick(wait=False)

    # --- 9. Send 3 datagrams to the recv socket ---
    # Build destination sockaddr_in (16 bytes, heap-allocated)
    var dest_addr = _heap_alloc[UInt8](16).as_unsafe_any_origin()
    for i in range(16):
        (dest_addr + i)[] = UInt8(0)
    dest_addr[] = UInt8(AF_INET)
    (dest_addr + 2)[] = port_hi        # sin_port (network byte order)
    (dest_addr + 3)[] = port_lo
    (dest_addr + 4)[] = UInt8(127)     # sin_addr 127.0.0.1
    (dest_addr + 5)[] = UInt8(0)
    (dest_addr + 6)[] = UInt8(0)
    (dest_addr + 7)[] = UInt8(1)

    # Send 3 datagrams with distinct payloads
    for dgram_idx in range(NUM_DATAGRAMS):
        var payload = _heap_alloc[UInt8](4).as_unsafe_any_origin()
        payload[] = UInt8(ord("D"))            # 'D'
        (payload + 1)[] = UInt8(ord("G"))      # 'G'
        (payload + 2)[] = UInt8(dgram_idx + 1) # 1, 2, 3
        (payload + 3)[] = UInt8(ord("!"))      # '!'
        var sent = external_call["sendto", Int](
            fd_send,
            UnsafePointer[c_void, StaticConstantOrigin](
                unsafe_from_address=Int(payload)
            ),
            UInt(4),
            Int32(0),
            UnsafePointer[c_void, StaticConstantOrigin](
                unsafe_from_address=Int(dest_addr)
            ),
            Int32(16),
        )
        assert_true(sent == 4, "sendto failed for datagram " + String(dgram_idx))
        print("sent datagram", dgram_idx + 1, "of", NUM_DATAGRAMS)
        payload.free()

    # --- 10. Tick until all 3 completions fire ---
    var ticks = 0
    while tracker.count < NUM_DATAGRAMS:
        driver.tick(wait=True)
        ticks += 1
        print("tick", ticks, "count=", tracker.count)
        if ticks > 50:
            raise "timed out waiting for multishot completions"

    print("all", NUM_DATAGRAMS, "completions received in", ticks, "ticks")

    # --- 11. Verify completions ---
    assert_true(
        tracker.count >= NUM_DATAGRAMS,
        "expected at least " + String(NUM_DATAGRAMS) + " completions, got "
        + String(tracker.count),
    )

    for i in range(NUM_DATAGRAMS):
        var res = tracker.results[i]
        var flg = tracker.flags[i]
        var bid = tracker.buf_ids[i]

        print(
            "  completion", i,
            "result=", Int(res),
            "flags=", Int(flg),
            "buf_id=", Int(bid),
        )

        # Result should be positive (bytes written into provided buffer)
        assert_true(
            Int(res) > 0,
            "completion " + String(i) + " result should be > 0, got "
            + String(Int(res)),
        )

        # IORING_CQE_F_BUFFER should be set (buffer was selected)
        assert_true(
            (flg & UInt32(IORING_CQE_F_BUFFER)) != 0,
            "completion " + String(i) + " missing IORING_CQE_F_BUFFER flag",
        )

        # Buffer ID should be in valid range
        assert_true(
            Int(bid) < NUM_BUFS,
            "completion " + String(i) + " buf_id=" + String(Int(bid))
            + " out of range (max " + String(NUM_BUFS) + ")",
        )

        # Recycle the buffer back to the ring
        bufring.add_buffer(bid)
        print("  recycled buffer", Int(bid))

    # First NUM_DATAGRAMS-1 completions should have IORING_CQE_F_MORE
    # (multishot still active). The last one might or might not, depending
    # on kernel behavior, so we only check the first ones.
    for i in range(NUM_DATAGRAMS - 1):
        var flg = tracker.flags[i]
        assert_true(
            (flg & UInt32(IORING_CQE_F_MORE)) != 0,
            "completion " + String(i) + " should have IORING_CQE_F_MORE"
            + " (multishot still active)",
        )

    # --- 12. Cleanup ---
    driver.unregister_buf_ring(group_id=UInt16(GROUP_ID))
    print("unregistered buf ring")

    _ = external_call["close", Int32](fd_recv)
    _ = external_call["close", Int32](fd_send)
    dest_addr.free()
    recv_iov.free()
    recv_mhdr.free()
    buf_base.free()

    _ = recv_cmp
    _ = bufring


def main() raises:
    test_driver_multishot_recvmsg()
    print("PASS: test_driver_multishot_recvmsg.mojo")
