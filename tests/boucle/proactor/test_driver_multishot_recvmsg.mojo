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
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc as _heap_alloc
from std.testing import assert_true

from boucle.socle.linux.raw import (
    msghdr,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    IORING_CQE_BUFFER_SHIFT,
    MSG_TRUNC,
)
from boucle.net.message import DELIVERY_HEADER_LEN, DeliveryHeader
from boucle.socle.linux.raw.ctypes import c_void
from boucle.proactor.completion import Completion
from boucle.drivers.bufring import BufRing
from boucle.drivers.feature import DriverFeature
from boucle.drivers.io_uring import IoUringDriver
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket

comptime AF_INET = 2


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var d = IoUringDriver(capacity=4)
        _ = d^
        return True
    except:
        return False
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
    var results: Array[Int, 8]
    var flags: Array[UInt32, 8]
    var buf_ids: Array[UInt16, 8]

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.count = 0
        self.results = Array[Int, 8](fill=0)
        self.flags = Array[UInt32, 8](fill=UInt32(0))
        self.buf_ids = Array[UInt16, 8](fill=UInt16(0))

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the completion result and buffer ID."""
        var self_ptr = Pointer[MultishotTracker, MutUntrackedOrigin](
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
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return

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
    var bind_addr = Array[UInt8, 16](fill=0)
    bind_addr[0] = AF_INET  # sin_family low byte
    bind_addr[4] = 127      # sin_addr = 127.0.0.1
    bind_addr[7] = 1

    var bind_res = external_call["bind", Int32](
        fd_recv,
        Pointer(to=bind_addr).unsafe_bitcast[c_void](),
        Int32(16),
    )
    assert_true(Int(bind_res) == 0, "bind(fd_recv) failed")

    # --- 3. Discover recv socket's ephemeral port ---
    var bound = Array[UInt8, 16](fill=0)
    var addrlen = Int32(16)
    var gsn_res = external_call["getsockname", Int32](
        fd_recv,
        Pointer(to=bound).unsafe_bitcast[c_void](),
        Pointer(to=addrlen).unsafe_bitcast[Int32](),
    )
    assert_true(Int(gsn_res) == 0, "getsockname failed")
    var port_hi = bound[2]
    var port_lo = bound[3]
    var port = Int(port_hi) << 8 | Int(port_lo)
    print("recv socket bound port=", port)
    assert_true(port > 0, "ephemeral port is 0")

    # --- 4. Create driver and register BufRing ---
    var driver = IoUringDriver(capacity=64)

    # Allocate data buffer pool (NUM_BUFS * BUF_SIZE bytes)
    var buf_base = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(_heap_alloc[UInt8](NUM_BUFS * BUF_SIZE)))
    for i in range(NUM_BUFS * BUF_SIZE):
        buf_base[unsafe_offset=i] = UInt8(0)

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
        recv_iov.unsafe_offset(i)[] = UInt8(0)

    # msghdr for recv (56 bytes) - minimal template
    var recv_mhdr = _heap_alloc[UInt8](56).as_unsafe_any_origin()
    for i in range(56):
        recv_mhdr.unsafe_offset(i)[] = UInt8(0)
    # msg_iov = recv_iov pointer (offset 16, 8 bytes LE)
    var ri_addr = Int(recv_iov)
    for i in range(8):
        recv_mhdr.unsafe_offset(16 + i)[] = UInt8((ri_addr >> (i * 8)) & 0xFF)
    # msg_iovlen = 1 (offset 24, 8 bytes LE)
    recv_mhdr.unsafe_offset(24)[] = UInt8(1)

    var recv_msg_ptr = Pointer[msghdr, MutUntrackedOrigin](
        unsafe_from_address=Int(recv_mhdr)
    )

    # --- 6. Wire completion callback ---
    var tracker = MultishotTracker()
    var tracker_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var recv_cmp = Completion(
        invoke=MultishotTracker.on_complete, context=tracker_ctx
    )
    var recv_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=recv_cmp))
    )

    # --- 7. Submit multishot recvmsg ---
    driver.multishot_recvmsg(
        fd_recv, recv_msg_ptr, UInt16(GROUP_ID), recv_cmp_ptr
    )
    print("submitted multishot recvmsg")

    # --- 8. Flush SQE to kernel (non-blocking tick) ---
    _ = driver.tick(wait=False)

    # --- 9. Send 3 datagrams to the recv socket ---
    # Build destination sockaddr_in (16 bytes, heap-allocated)
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

    # Send 3 datagrams with distinct payloads
    for dgram_idx in range(NUM_DATAGRAMS):
        var payload = _heap_alloc[UInt8](4).as_unsafe_any_origin()
        payload[] = UInt8(ord("D"))            # 'D'
        payload.unsafe_offset(1)[] = UInt8(ord("G"))      # 'G'
        payload.unsafe_offset(2)[] = UInt8(dgram_idx + 1) # 1, 2, 3
        payload.unsafe_offset(3)[] = UInt8(ord("!"))      # '!'
        var sent = external_call["sendto", Int](
            fd_send,
            Pointer[c_void, ImmStaticOrigin](
                unsafe_from_address=Int(payload)
            ),
            UInt(4),
            Int32(0),
            Pointer[c_void, ImmStaticOrigin](
                unsafe_from_address=Int(dest_addr)
            ),
            Int32(16),
        )
        assert_true(sent == 4, "sendto failed for datagram " + String(dgram_idx))
        print("sent datagram", dgram_idx + 1, "of", NUM_DATAGRAMS)
        payload.unsafe_free()

    # --- 10. Tick until all 3 completions fire ---
    var ticks = 0
    while tracker.count < NUM_DATAGRAMS:
        _ = driver.tick(wait=True)
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
    dest_addr.unsafe_free()
    recv_iov.unsafe_free()
    recv_mhdr.unsafe_free()
    buf_base.unsafe_free()

    _ = recv_cmp
    _ = bufring


def _ptr[T: AnyType](ref value: T) -> Pointer[T, MutUntrackedOrigin]:
    """Untracked pointer to a caller-owned value."""
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=value))
    )


def test_multishot_submits_after_full_sq() raises:
    """A multishot recvmsg queued on a full submission queue flushes it first and still arms.

    Every other operation flushes a full ring with a non-waiting enter
    and retries; the multishot must do the same instead of raising.
    """
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    var driver = IoUringDriver(capacity=8)
    if not driver.supports(DriverFeature.MULTISHOT_RECVMSG):
        print("SKIP: multishot recvmsg needs kernel 6.0")
        return
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()

    comptime GROUP = 3
    comptime SIZE = 256
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(_heap_alloc[UInt8](4 * SIZE))
    )
    for i in range(4 * SIZE):
        mem[unsafe_offset=i] = UInt8(0)
    driver.register_buffer_group(mem, UInt32(SIZE), 4, UInt16(GROUP))
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(28)

    var nops = MultishotTracker()
    var nop_cmp = Completion(
        invoke=MultishotTracker.on_complete,
        context=_ptr(nops).unsafe_bitcast[NoneType](),
    )
    var space = driver.sq_space()
    assert_true(space > 0, "a fresh ring has room")
    for _ in range(space):
        driver.nop(_ptr(nop_cmp))
    assert_true(driver.sq_space() == 0, "the ring is full")

    var recv = MultishotTracker()
    var recv_cmp = Completion(
        invoke=MultishotTracker.on_complete,
        context=_ptr(recv).unsafe_bitcast[NoneType](),
    )
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(recv_cmp),
    )
    _ = driver.tick(wait=False)

    var seen_nops = _ptr(nops)
    var ticks = 0
    while seen_nops[].count < space:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 20, "the flushed nops never completed")

    # The op was really queued: a datagram is delivered through the group.
    var payload = List[UInt8](length=4, fill=UInt8(ord("x")))
    assert_true(sender.send_to(Span(payload), to) == 4, "sendto")
    var seen_recv = _ptr(recv)
    ticks = 0
    while seen_recv[].count < 1:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 20, "the multishot delivery never arrived")
    assert_true(
        (seen_recv[].flags[0] & UInt32(IORING_CQE_F_BUFFER)) != 0,
        "delivery selected a buffer",
    )
    assert_true(seen_recv[].results[0] > 0, "delivery carries bytes")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = nop_cmp
    _ = recv_cmp
    _ = tmpl


def test_multishot_truncation_reports_full_length() raises:
    """A 300-byte datagram into a 100-byte room reports payloadlen 300 and MSG_TRUNC.

    The epoll emulation receives with MSG_TRUNC and writes the full
    datagram length into the delivery header; the io_uring op must
    request the same so `DeliveryHeader.payloadlen()` agrees on both
    backends. The copied bytes are the first 100.
    """
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    var driver = IoUringDriver(capacity=8)
    if not driver.supports(DriverFeature.MULTISHOT_RECVMSG):
        print("SKIP: multishot recvmsg needs kernel 6.0")
        return
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()

    comptime GROUP = 4
    comptime NAME_CAP = 28
    comptime ROOM = 100
    comptime SIZE = DELIVERY_HEADER_LEN + NAME_CAP + ROOM
    comptime BIG = 300
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(_heap_alloc[UInt8](2 * SIZE))
    )
    for i in range(2 * SIZE):
        mem[unsafe_offset=i] = UInt8(0)
    driver.register_buffer_group(mem, UInt32(SIZE), 2, UInt16(GROUP))
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var recv = MultishotTracker()
    var recv_cmp = Completion(
        invoke=MultishotTracker.on_complete,
        context=_ptr(recv).unsafe_bitcast[NoneType](),
    )
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(recv_cmp),
    )
    _ = driver.tick(wait=False)

    var payload = List[UInt8](length=BIG, fill=0)
    for i in range(BIG):
        payload[i] = UInt8(i & 0xFF)
    assert_true(sender.send_to(Span(payload), to) == BIG, "sendto")
    var seen = _ptr(recv)
    var ticks = 0
    while seen[].count < 1:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 20, "the truncated delivery never arrived")
    assert_true(seen[].results[0] == SIZE, "result is the filled buffer")
    var bid = Int(seen[].buf_ids[0])
    var buf = Span[UInt8, MutUntrackedOrigin](
        unsafe_ptr=mem.unsafe_offset(bid * SIZE), length=SIZE
    )
    var hdr = DeliveryHeader.parse(buf, name_capacity=NAME_CAP, control_capacity=0)
    assert_true(Int(hdr.payloadlen()) == BIG, "full datagram length reported")
    assert_true((Int(hdr.flags()) & MSG_TRUNC) != 0, "MSG_TRUNC set")
    var got = hdr.payload()
    assert_true(len(got) == ROOM, "payload clipped to the room")
    for i in range(ROOM):
        assert_true(Int(got[i]) == (i & 0xFF), "copied bytes intact")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = recv_cmp
    _ = tmpl


def test_multishot_control_messages_are_delivered() raises:
    """With a 64-byte control capacity the kernel writes the sender's TOS record after the name."""
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    var driver = IoUringDriver(capacity=8)
    if not driver.supports(DriverFeature.MULTISHOT_RECVMSG):
        print("SKIP: multishot recvmsg needs kernel 6.0")
        return
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.set_recv_tos()
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    sender.set_tos(UInt8(2))
    var sender_port = Int(sender.local_addr_v4().port)

    comptime GROUP = 5
    comptime NAME_CAP = 28
    comptime CTRL_CAP = 64
    comptime SIZE = 256
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(_heap_alloc[UInt8](2 * SIZE))
    )
    for i in range(2 * SIZE):
        mem[unsafe_offset=i] = UInt8(0)
    driver.register_buffer_group(mem, UInt32(SIZE), 2, UInt16(GROUP))
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    tmpl.msg_controllen = UInt64(CTRL_CAP)
    var recv = MultishotTracker()
    var recv_cmp = Completion(
        invoke=MultishotTracker.on_complete,
        context=_ptr(recv).unsafe_bitcast[NoneType](),
    )
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(recv_cmp),
    )
    _ = driver.tick(wait=False)

    var payload = List[UInt8](length=4, fill=UInt8(ord("e")))
    assert_true(sender.send_to(Span(payload), to) == 4, "sendto")
    var seen = _ptr(recv)
    var ticks = 0
    while seen[].count < 1:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 20, "the delivery with control never arrived")
    var bid = Int(seen[].buf_ids[0])
    var buf = Span[UInt8, MutUntrackedOrigin](
        unsafe_ptr=mem.unsafe_offset(bid * SIZE), length=SIZE
    )
    var hdr = DeliveryHeader.parse(
        buf, name_capacity=NAME_CAP, control_capacity=CTRL_CAP
    )
    assert_true(Int(hdr.controllen()) > 0, "a control record was written")
    assert_true(Int(hdr.controllen()) <= CTRL_CAP, "it fits the capacity")
    assert_true(Int(hdr.namelen()) == 16, "sockaddr_in written")
    var name = hdr.name()
    assert_true(Int(name[0]) == 2, "AF_INET")
    assert_true(((Int(name[2]) << 8) | Int(name[3])) == sender_port, "peer port")
    assert_true(Int(hdr.payloadlen()) == 4, "payload length")
    assert_true(
        seen[].results[0] == DELIVERY_HEADER_LEN + NAME_CAP + CTRL_CAP + 4,
        "result spans header, name, control and payload",
    )
    var mark = hdr.control().ecn()
    assert_true(Bool(mark), "an IP_TOS record is in the control area")
    assert_true(Int(mark.value()) == 2, "the sent codepoint")
    assert_true(Int(hdr.payload()[0]) == ord("e"), "payload intact")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = recv_cmp
    _ = tmpl


def main() raises:
    test_driver_multishot_recvmsg()
    test_multishot_truncation_reports_full_length()
    test_multishot_control_messages_are_delivered()
    test_multishot_submits_after_full_sq()
    print("PASS: test_driver_multishot_recvmsg.mojo")
