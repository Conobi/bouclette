from boucle.completion import _LegacyCompletionLoop as CompletionLoop, _LegacyCompletionHandler as CompletionHandler
from boucle.socle.linux.raw import IORING_CQE_F_MORE
from boucle.socle.linux.raw.ctypes import c_void
from boucle.handle import RawHandle
from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import assert_equal, assert_true


struct Counter(CompletionHandler):
    var count: Int
    var last_token: UInt64
    var last_result: Int32

    def __init__(out self):
        self.count = 0
        self.last_token = 0
        self.last_result = 0

    def __init__(out self, *, deinit take: Self):
        self.count = take.count
        self.last_token = take.last_token
        self.last_result = take.last_result

    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        self.count += 1
        self.last_token = token
        self.last_result = result


def test_nop_single() raises:
    var loop = CompletionLoop(Counter(), sq_entries=8)
    loop.submit_nop(token=42)
    loop.run()
    assert_equal(loop._handler.count, 1)
    assert_equal(loop._handler.last_token, UInt64(42))
    assert_equal(loop._handler.last_result, Int32(0))


def test_nop_multiple() raises:
    var loop = CompletionLoop(Counter(), sq_entries=8)
    for i in range(5):
        loop.submit_nop(token=UInt64(i))
    loop.run()
    assert_equal(loop._handler.count, 5)


def test_nop_batched() raises:
    var loop = CompletionLoop(Counter(), sq_entries=4)
    for i in range(12):
        if i > 0 and i % 4 == 0:
            loop.poll(wait_nr=1)
        loop.submit_nop(token=UInt64(i))
    loop.run()
    assert_equal(loop._handler.count, 12)


struct CqeRecorder(CompletionHandler):
    """Records up to 4 CQEs as (token, result) pairs for unordered assertions."""
    var tokens: InlineArray[UInt64, 4]
    var results: InlineArray[Int32, 4]
    var count: Int

    def __init__(out self):
        self.tokens = InlineArray[UInt64, 4](fill=0)
        self.results = InlineArray[Int32, 4](fill=0)
        self.count = 0

    def __init__(out self, *, deinit take: Self):
        self.tokens = take.tokens
        self.results = take.results
        self.count = take.count

    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        if self.count < 4:
            self.tokens[self.count] = token
            self.results[self.count] = result
        self.count += 1


def test_submit_cancel_cancels_pending_recv() raises:
    # Open a connected AF_UNIX socketpair; one side has no data, so a recv
    # there will park in the kernel waiting for bytes.
    # socketpair(AF_UNIX=1, SOCK_STREAM=1, protocol=0, sv).
    var sv = InlineArray[Int32, 2](fill=0)
    var rc = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1),  # SOCK_STREAM
        Int32(0),
        UnsafePointer(to=sv).bitcast[Int32](),
    )
    assert_equal(Int(rc), 0)
    var read_fd: RawHandle = sv[0]
    var write_fd: RawHandle = sv[1]

    var loop = CompletionLoop(CqeRecorder(), sq_entries=8)

    # Submit a recv that will park in the kernel.
    var buf = List[UInt8](length=16, fill=0)
    var buf_ptr = UnsafePointer[Int8, StaticConstantOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    loop.submit_recv(read_fd, buf_ptr, 16, token=42)

    # Cancel it by user_data. The cancel CQE carries token=99.
    loop.submit_cancel(token=99, target_user_data=42)

    # Drain until both CQEs arrive (order is not guaranteed).
    while loop._handler.count < 2:
        loop.poll(wait_nr=1)

    assert_equal(loop._handler.count, 2)

    # Find the recv's CQE (token 42) and the cancel's CQE (token 99).
    var recv_idx = -1
    var cancel_idx = -1
    for i in range(2):
        if loop._handler.tokens[i] == UInt64(42):
            recv_idx = i
        elif loop._handler.tokens[i] == UInt64(99):
            cancel_idx = i
    assert_true(recv_idx >= 0, "recv CQE (token=42) missing")
    assert_true(cancel_idx >= 0, "cancel CQE (token=99) missing")

    # Recv must report -ECANCELED (-125 on x86_64).
    assert_equal(loop._handler.results[recv_idx], Int32(-125))
    # Cancel itself reports 0 (cancelled in flight) or -ENOENT/-EALREADY if the
    # target raced to completion. We never wrote anything, so 0 is expected, but
    # accept the other valid outcomes to stay robust against kernel scheduling.
    var cr = loop._handler.results[cancel_idx]
    assert_true(
        cr == Int32(0) or cr == Int32(-2) or cr == Int32(-114),
        "cancel CQE result must be 0, -ENOENT (-2), or -EALREADY (-114)",
    )

    _ = external_call["close", Int32](read_fd)
    _ = external_call["close", Int32](write_fd)


struct MultishotRecorder(CompletionHandler):
    """Records CQE flags so the test can check IORING_CQE_F_MORE was set."""
    var count: Int
    var saw_more: Int  # number of CQEs with IORING_CQE_F_MORE set
    var saw_terminal: Int  # number of CQEs with IORING_CQE_F_MORE cleared

    def __init__(out self):
        self.count = 0
        self.saw_more = 0
        self.saw_terminal = 0

    def __init__(out self, *, deinit take: Self):
        self.count = take.count
        self.saw_more = take.saw_more
        self.saw_terminal = take.saw_terminal

    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        self.count += 1
        if (flags & UInt32(IORING_CQE_F_MORE)) != 0:
            self.saw_more += 1
        else:
            self.saw_terminal += 1


def test_accept_multishot_pending_no_underflow() raises:
    """Multishot accept produces multiple CQEs per submission; only the
    terminal CQE (F_MORE cleared) must retire the op. Verifies _pending
    doesn't underflow after intermediate F_MORE-bearing CQEs.
    """
    comptime AF_INET6 = 10
    comptime SOCK_STREAM = 1

    # Listener on [::1]:0
    var listen_fd = external_call["socket", Int32](
        Int32(AF_INET6), Int32(SOCK_STREAM), Int32(0)
    )
    assert_true(Int(listen_fd) >= 0, "socket() failed")

    var addr = InlineArray[UInt8, 28](fill=0)
    addr[0] = UInt8(AF_INET6)
    addr[8 + 15] = UInt8(1)  # ::1
    var addr_ptr = UnsafePointer(to=addr).bitcast[c_void]()
    var bind_res = external_call["bind", Int32](
        listen_fd, addr_ptr, Int32(28)
    )
    assert_equal(Int(bind_res), 0)
    var listen_res = external_call["listen", Int32](listen_fd, Int32(4))
    assert_equal(Int(listen_res), 0)

    # Read the ephemeral port back.
    var bound = InlineArray[UInt8, 28](fill=0)
    var bound_len = Int32(28)
    var gn_res = external_call["getsockname", Int32](
        listen_fd,
        UnsafePointer(to=bound).bitcast[c_void](),
        UnsafePointer(to=bound_len).bitcast[Int32](),
    )
    assert_equal(Int(gn_res), 0)
    var port_hi = bound[2]
    var port_lo = bound[3]

    var loop = CompletionLoop(MultishotRecorder(), sq_entries=8)
    loop.submit_accept_multishot(RawHandle(Int(listen_fd)), token=99)
    assert_equal(Int(loop._pending), 1)

    # Open three clients in sequence and drain each accept CQE.
    for _ in range(3):
        var client_fd = external_call["socket", Int32](
            Int32(AF_INET6), Int32(SOCK_STREAM), Int32(0)
        )
        assert_true(Int(client_fd) >= 0)
        var dest = InlineArray[UInt8, 28](fill=0)
        dest[0] = UInt8(AF_INET6)
        dest[2] = port_hi
        dest[3] = port_lo
        dest[8 + 15] = UInt8(1)
        var cr = external_call["connect", Int32](
            client_fd,
            UnsafePointer(to=dest).bitcast[c_void](),
            Int32(28),
        )
        assert_equal(Int(cr), 0)

        loop.poll(wait_nr=1)
        _ = external_call["close", Int32](client_fd)

    # We received at least three multishot CQEs. Each carried F_MORE since the
    # accept op is still armed. _pending must remain 1 (no terminal CQE yet).
    assert_true(
        loop._handler.saw_more >= 3,
        "expected >=3 F_MORE CQEs, got " + String(loop._handler.saw_more),
    )
    assert_equal(Int(loop._handler.saw_terminal), 0)
    assert_equal(
        Int(loop._pending),
        1,
        "multishot accept must keep _pending=1 across F_MORE CQEs; was "
        + String(Int(loop._pending)),
    )

    _ = external_call["close", Int32](listen_fd)


def main() raises:
    test_nop_single()
    test_nop_multiple()
    test_nop_batched()
    test_submit_cancel_cancels_pending_recv()
    test_accept_multishot_pending_no_underflow()
    print("All completion loop tests passed.")
