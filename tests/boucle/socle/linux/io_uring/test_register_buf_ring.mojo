from boucle import CompletionLoop, CompletionHandler
from boucle.proactor.bufring import BufRing
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


def test_register_buf_ring() raises:
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
        UnsafePointer(to=optval).bitcast[c_void](),
        Int32(4),
    )
    var addr = InlineArray[UInt8, 28](fill=0)
    addr[0] = UInt8(AF_INET6)
    addr[8 + 15] = UInt8(1)
    var addr_ptr = UnsafePointer(to=addr).bitcast[c_void]()
    assert_equal(
        Int(external_call["bind", Int32](listen_fd, addr_ptr, Int32(28))),
        0,
    )
    assert_equal(
        Int(external_call["listen", Int32](listen_fd, Int32(1))), 0
    )
    var bound = InlineArray[UInt8, 28](fill=0)
    var addrlen = Int32(28)
    _ = external_call["getsockname", Int32](
        listen_fd,
        UnsafePointer(to=bound).bitcast[c_void](),
        UnsafePointer(to=addrlen).bitcast[Int32](),
    )
    var port_hi = bound[2]
    var port_lo = bound[3]

    # --- 2. Client socket connects to listener ---
    var client_fd = external_call["socket", Int32](
        Int32(AF_INET6), Int32(SOCK_STREAM), Int32(0)
    )
    var dest = InlineArray[UInt8, 28](fill=0)
    dest[0] = UInt8(AF_INET6)
    dest[2] = port_hi
    dest[3] = port_lo
    dest[8 + 15] = UInt8(1)
    assert_equal(
        Int(
            external_call["connect", Int32](
                client_fd,
                UnsafePointer(to=dest).bitcast[c_void](),
                Int32(28),
            )
        ),
        0,
    )

    # --- 3. Accept the server-side socket ---
    var server_fd = external_call["accept", Int32](
        listen_fd,
        null_ptr[c_void, StaticConstantOrigin](),
        null_ptr[Int32, StaticConstantOrigin](),
    )
    assert_true(Int(server_fd) >= 0, "accept() failed")

    # --- 4. Allocate buffer pool: 4 × 1024 ---
    comptime BUF_SIZE = 1024
    comptime BUF_COUNT = 4
    var pool = _heap_alloc[UInt8](BUF_SIZE * BUF_COUNT).as_unsafe_any_origin()
    for i in range(BUF_SIZE * BUF_COUNT):
        pool[i] = UInt8(0)

    # --- 5. CompletionLoop + register_buf_ring + submit_recv_multishot ---
    var loop = CompletionLoop(Tracker())
    var bring = loop.register_buf_ring(
        pool,
        buf_size=UInt32(BUF_SIZE),
        count=BUF_COUNT,
        group_id=UInt16(11),
    )
    assert_equal(Int(bring.ring_entries), BUF_COUNT)
    assert_equal(Int(bring.bgid), 11)

    loop.submit_recv_multishot(
        fd=server_fd, buf_group=UInt16(11), token=200
    )

    # --- 6. Send "hello" from client ---
    var msg = InlineArray[UInt8, 5](fill=0)
    msg[0] = UInt8(ord("h"))
    msg[1] = UInt8(ord("e"))
    msg[2] = UInt8(ord("l"))
    msg[3] = UInt8(ord("l"))
    msg[4] = UInt8(ord("o"))
    var sent = external_call["send", Int64](
        client_fd,
        UnsafePointer(to=msg).bitcast[c_void](),
        UInt64(5),
        Int32(0),
    )
    assert_equal(Int(sent), 5)

    # --- 7. Poll for the recv CQE ---
    loop.poll(wait_nr=1)
    var recv_idx = -1
    for i in range(loop._handler.call_count):
        if loop._handler.tokens[i] == 200:
            recv_idx = i
            break
    assert_true(recv_idx >= 0, "no recv CQE")

    var recv_result = loop._handler.results[recv_idx]
    var recv_flags = loop._handler.flags_arr[recv_idx]
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
    var buf_start = pool + buf_id * BUF_SIZE
    assert_equal(Int(buf_start[0]), ord("h"))
    assert_equal(Int(buf_start[1]), ord("e"))
    assert_equal(Int(buf_start[2]), ord("l"))
    assert_equal(Int(buf_start[3]), ord("l"))
    assert_equal(Int(buf_start[4]), ord("o"))

    # --- 8. Return buffer via add_buffer (userspace store, no SQE) ---
    bring.add_buffer(UInt16(buf_id))

    # --- 9. Send another payload, kernel should pick a buffer again ---
    var msg2 = InlineArray[UInt8, 3](fill=0)
    msg2[0] = UInt8(ord("h"))
    msg2[1] = UInt8(ord("i"))
    msg2[2] = UInt8(ord("!"))
    var sent2 = external_call["send", Int64](
        client_fd,
        UnsafePointer(to=msg2).bitcast[c_void](),
        UInt64(3),
        Int32(0),
    )
    assert_equal(Int(sent2), 3)

    loop.poll(wait_nr=1)
    var recv2_idx = -1
    for i in range(recv_idx + 1, loop._handler.call_count):
        if loop._handler.tokens[i] == 200:
            recv2_idx = i
            break
    assert_true(recv2_idx >= 0, "no second recv CQE")
    var recv2_flags = loop._handler.flags_arr[recv2_idx]
    var recv2_result = loop._handler.results[recv2_idx]
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
    var buf2_start = pool + buf_id2 * BUF_SIZE
    assert_equal(Int(buf2_start[0]), ord("h"))
    assert_equal(Int(buf2_start[1]), ord("i"))
    assert_equal(Int(buf2_start[2]), ord("!"))

    bring.add_buffer(UInt16(buf_id2))

    # --- 10. Cleanup ---
    loop.unregister_buf_ring(UInt16(11))
    _ = external_call["close", Int32](client_fd)
    _ = external_call["close", Int32](server_fd)
    _ = external_call["close", Int32](listen_fd)
    pool.free()
    print("test_register_buf_ring PASSED")


def main() raises:
    test_register_buf_ring()
