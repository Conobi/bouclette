"""Test register_buf_ring + multishot recv via IoUringDriver.

Exercises the BufRing path: register, recv, recycle, recv again.
"""

from boucle.drivers.io_uring import IoUringDriver
from boucle.proactor.completion import Completion
from boucle.proactor.bufring import BufRing
from boucle.socle.ptr import null_ptr
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.linux.raw import (
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
        var d = IoUringDriver(sq_entries=4)
        _ = d^
        return True
    except:
        return False
comptime SOCK_STREAM = 1
comptime IPPROTO_IPV6 = 41
comptime IPV6_V6ONLY = 26


struct Tracker:
    """Records callback invocations for multishot recv completions."""

    var call_count: Int
    var results: Array[Int32, 8]
    var flags_arr: Array[UInt32, 8]

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.call_count = 0
        self.results = Array[Int32, 8](fill=0)
        self.flags_arr = Array[UInt32, 8](fill=0)

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int32,
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


def test_register_buf_ring() raises:
    """Register a BufRing, recv with it, recycle, recv again."""
    # --- 1. TCP listener on [::1]:0 ---
    var listen_fd = external_call["socket", Int32](
        Int32(AF_INET6), Int32(SOCK_STREAM), Int32(0)
    )
    assert_true(Int(listen_fd) >= 0, "socket() failed")
    var optval = Int32(0)
    _ = external_call["setsockopt", Int32](
        listen_fd,
        Int32(IPPROTO_IPV6),
        Int32(IPV6_V6ONLY),
        Pointer(to=optval).unsafe_bitcast[c_void](),
        Int32(4),
    )
    var addr = Array[UInt8, 28](fill=0)
    addr[0] = UInt8(AF_INET6)
    addr[8 + 15] = UInt8(1)
    var addr_ptr = Pointer(to=addr).unsafe_bitcast[c_void]()
    assert_equal(
        Int(external_call["bind", Int32](listen_fd, addr_ptr, Int32(28))),
        0,
    )
    assert_equal(
        Int(external_call["listen", Int32](listen_fd, Int32(1))), 0
    )
    var bound = Array[UInt8, 28](fill=0)
    var addrlen = Int32(28)
    _ = external_call["getsockname", Int32](
        listen_fd,
        Pointer(to=bound).unsafe_bitcast[c_void](),
        Pointer(to=addrlen).unsafe_bitcast[Int32](),
    )
    var port_hi = bound[2]
    var port_lo = bound[3]

    # --- 2. Client socket connects to listener ---
    var client_fd = external_call["socket", Int32](
        Int32(AF_INET6), Int32(SOCK_STREAM), Int32(0)
    )
    var dest = Array[UInt8, 28](fill=0)
    dest[0] = UInt8(AF_INET6)
    dest[2] = port_hi
    dest[3] = port_lo
    dest[8 + 15] = UInt8(1)
    assert_equal(
        Int(
            external_call["connect", Int32](
                client_fd,
                Pointer(to=dest).unsafe_bitcast[c_void](),
                Int32(28),
            )
        ),
        0,
    )

    # --- 3. Accept the server-side socket ---
    var server_fd = external_call["accept", Int32](
        listen_fd,
        null_ptr[c_void, ImmStaticOrigin](),
        null_ptr[Int32, ImmStaticOrigin](),
    )
    assert_true(Int(server_fd) >= 0, "accept() failed")

    # --- 4. Allocate buffer pool: 4 x 1024 ---
    comptime BUF_SIZE = 1024
    comptime BUF_COUNT = 4
    var pool = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(_heap_alloc[UInt8](BUF_SIZE * BUF_COUNT)))
    for i in range(BUF_SIZE * BUF_COUNT):
        pool[unsafe_offset=i] = UInt8(0)

    # --- 5. IoUringDriver + register_buf_ring + submit_recv_multishot ---
    var driver = IoUringDriver()
    var bring = driver.register_buf_ring(
        pool,
        buf_size=UInt32(BUF_SIZE),
        count=BUF_COUNT,
        group_id=UInt16(11),
    )
    assert_equal(Int(bring.ring_entries), BUF_COUNT)
    assert_equal(Int(bring.bgid), 11)

    # Wire recv multishot completion.
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
    driver.submit_recv_multishot(
        fd=server_fd, buf_group=UInt16(11), c=recv_cmp_ptr
    )

    # --- 6. Send "hello" from client ---
    var msg = Array[UInt8, 5](fill=0)
    msg[0] = UInt8(ord("h"))
    msg[1] = UInt8(ord("e"))
    msg[2] = UInt8(ord("l"))
    msg[3] = UInt8(ord("l"))
    msg[4] = UInt8(ord("o"))
    var sent = external_call["send", Int64](
        client_fd,
        Pointer(to=msg).unsafe_bitcast[c_void](),
        UInt64(5),
        Int32(0),
    )
    assert_equal(Int(sent), 5)

    # --- 7. Tick for the recv CQE ---
    while tracker.call_count < 1:
        _ = driver.tick(wait=True)

    var recv_result = tracker.results[0]
    var recv_flags = tracker.flags_arr[0]
    print(
        "recv: result=",
        recv_result,
        " flags=0x",
        hex(Int(recv_flags)),
    )

    assert_true(
        Int(recv_flags) & IORING_CQE_F_BUFFER != 0,
        "F_BUFFER not set",
    )
    assert_equal(Int(recv_result), 5)

    var buf_id = (Int(recv_flags) >> IORING_CQE_BUFFER_SHIFT) & 0xFFFF
    print("buf_id=", buf_id)
    assert_true(buf_id < BUF_COUNT, "buf_id out of range")

    # Payload at offset 0 of selected buffer
    var buf_start = pool.unsafe_offset(buf_id * BUF_SIZE)
    assert_equal(Int(buf_start[unsafe_offset=0]), ord("h"))
    assert_equal(Int(buf_start[unsafe_offset=1]), ord("e"))
    assert_equal(Int(buf_start[unsafe_offset=2]), ord("l"))
    assert_equal(Int(buf_start[unsafe_offset=3]), ord("l"))
    assert_equal(Int(buf_start[unsafe_offset=4]), ord("o"))

    # --- 8. Return buffer via add_buffer (userspace store, no SQE) ---
    bring.add_buffer(UInt16(buf_id))

    # --- 9. Send another payload, kernel should pick a buffer again ---
    var msg2 = Array[UInt8, 3](fill=0)
    msg2[0] = UInt8(ord("h"))
    msg2[1] = UInt8(ord("i"))
    msg2[2] = UInt8(ord("!"))
    var sent2 = external_call["send", Int64](
        client_fd,
        Pointer(to=msg2).unsafe_bitcast[c_void](),
        UInt64(3),
        Int32(0),
    )
    assert_equal(Int(sent2), 3)

    while tracker.call_count < 2:
        _ = driver.tick(wait=True)

    var recv2_flags = tracker.flags_arr[1]
    var recv2_result = tracker.results[1]
    print(
        "second recv: result=",
        recv2_result,
        " flags=0x",
        hex(Int(recv2_flags)),
    )
    assert_equal(Int(recv2_result), 3)
    assert_true(
        Int(recv2_flags) & IORING_CQE_F_BUFFER != 0,
        "second F_BUFFER not set",
    )

    var buf_id2 = (Int(recv2_flags) >> IORING_CQE_BUFFER_SHIFT) & 0xFFFF
    var buf2_start = pool.unsafe_offset(buf_id2 * BUF_SIZE)
    assert_equal(Int(buf2_start[unsafe_offset=0]), ord("h"))
    assert_equal(Int(buf2_start[unsafe_offset=1]), ord("i"))
    assert_equal(Int(buf2_start[unsafe_offset=2]), ord("!"))

    bring.add_buffer(UInt16(buf_id2))

    # --- 10. Cleanup ---
    driver.unregister_buf_ring(UInt16(11))
    _ = external_call["close", Int32](client_fd)
    _ = external_call["close", Int32](server_fd)
    _ = external_call["close", Int32](listen_fd)
    pool.unsafe_free()
    _ = recv_cmp
    _ = bring
    print("test_register_buf_ring PASSED")


def main() raises:
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_register_buf_ring()
