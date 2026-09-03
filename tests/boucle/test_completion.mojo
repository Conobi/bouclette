"""Tests for the opaque CompletionLoop and io_uring-specific operations.

Covers basic nop operations (single, multiple, batched), async cancel,
and multishot accept (io_uring-specific, skipped when unavailable).
"""

from boucle.completion import CompletionLoop
from boucle.proactor.completion import Completion
from boucle.drivers.io_uring import IoUringDriver
from boucle.socle.linux.raw import IORING_CQE_F_MORE
from boucle.socle.linux.raw.ctypes import c_void
from boucle.handle import RawHandle
from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc as _heap_alloc
from std.testing import assert_equal, assert_true


# ── Shared tracker and callback ──────────────────────────────────────────────


struct Counter:
    """Counts callback invocations and records the last result."""

    var count: Int
    var last_result: Int

    def __init__(out self):
        """Construct a zeroed counter."""
        self.count = 0
        self.last_result = 0

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that increments count and stores result."""
        var self_ptr = Pointer[Counter, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].count += 1
        self_ptr[].last_result = result


struct ResultSlot:
    """Records a single completion result and whether it fired."""

    var result: Int
    var fired: Bool

    def __init__(out self):
        """Construct an unfired slot."""
        self.result = 0
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the result."""
        var self_ptr = Pointer[ResultSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


# ── Nop tests (portable, CompletionLoop) ─────────────────────────────────────


def test_nop_single() raises:
    """Submit a single NOP and verify the callback fires."""
    var loop = CompletionLoop(sq_entries=8)
    var tracker = Counter()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var cmp = Completion(invoke=Counter.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )
    loop.submit_nop(cmp_ptr)
    _ = loop.tick(wait=True)

    assert_equal(tracker.count, 1)
    assert_equal(Int(tracker.last_result), 0)
    _ = cmp


def test_nop_multiple() raises:
    """Submit five NOPs and verify all callbacks fire."""
    var loop = CompletionLoop(sq_entries=8)
    var tracker = Counter()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )

    var cmps = Pointer[Completion, MutUntrackedOrigin](unsafe_from_address=Int(_heap_alloc[Completion](5)))
    for i in range(5):
        cmps.unsafe_offset(i).unsafe_write(Completion(invoke=Counter.on_complete, context=ctx))

    for i in range(5):
        loop.submit_nop(cmps.unsafe_offset(i))
    _ = loop.tick(wait=True)

    assert_equal(tracker.count, 5)

    for i in range(5):
        _ = cmps.unsafe_offset(i).unsafe_take_pointee()
    cmps.unsafe_free()


def test_nop_batched() raises:
    """Submit 12 NOPs through a 4-entry SQ, ticking between batches."""
    var loop = CompletionLoop(sq_entries=4)
    var tracker = Counter()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )

    var cmps = Pointer[Completion, MutUntrackedOrigin](unsafe_from_address=Int(_heap_alloc[Completion](12)))
    for i in range(12):
        cmps.unsafe_offset(i).unsafe_write(Completion(invoke=Counter.on_complete, context=ctx))

    for i in range(12):
        if i > 0 and i % 4 == 0:
            _ = loop.tick(wait=True)
        loop.submit_nop(cmps.unsafe_offset(i))

    # Drain remaining completions.
    while tracker.count < 12:
        _ = loop.tick(wait=True)

    assert_equal(tracker.count, 12)

    for i in range(12):
        _ = cmps.unsafe_offset(i).unsafe_take_pointee()
    cmps.unsafe_free()


# ── Cancel test (portable, CompletionLoop) ───────────────────────────────────


def test_submit_cancel_cancels_pending_recv() raises:
    """Cancel a pending recv on a socketpair and verify both CQEs."""
    # socketpair(AF_UNIX=1, SOCK_STREAM=1, protocol=0, sv).
    var sv = Array[Int32, 2](fill=0)
    var rc = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1),  # SOCK_STREAM
        Int32(0),
        Pointer(to=sv).unsafe_bitcast[Int32](),
    )
    assert_equal(Int(rc), 0)
    var read_fd: RawHandle = sv[0]
    var write_fd: RawHandle = sv[1]

    var loop = CompletionLoop(sq_entries=8)

    # Wire recv completion.
    var recv_slot = ResultSlot()
    var recv_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=recv_slot))
    )
    var recv_cmp = Completion(invoke=ResultSlot.on_complete, context=recv_ctx)
    var recv_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=recv_cmp))
    )

    # Wire cancel completion.
    var cancel_slot = ResultSlot()
    var cancel_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cancel_slot))
    )
    var cancel_cmp = Completion(invoke=ResultSlot.on_complete, context=cancel_ctx)
    var cancel_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cancel_cmp))
    )

    # Submit a recv that will park (no data on the socket).
    var buf = List[UInt8](length=16, fill=0)
    var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    loop.submit_recv(read_fd, buf_ptr, UInt32(16), recv_cmp_ptr)

    # Cancel it by Completion pointer.
    loop.submit_cancel(recv_cmp_ptr, cancel_cmp_ptr)

    # Drain until both CQEs arrive.
    var ticks = 0
    while not recv_slot.fired or not cancel_slot.fired:
        _ = loop.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for cancel completion"

    # Recv must report -ECANCELED (-125 on x86_64).
    assert_equal(recv_slot.result, -125)

    # Cancel itself reports 0 (cancelled in flight) or -ENOENT/-EALREADY
    # if the target raced to completion.
    var cr = cancel_slot.result
    assert_true(
        cr == 0 or cr == -2 or cr == -114,
        "cancel CQE result must be 0, -ENOENT (-2), or -EALREADY (-114)",
    )

    _ = external_call["close", Int32](read_fd)
    _ = external_call["close", Int32](write_fd)

    # Keep completions alive past the callback.
    _ = recv_cmp
    _ = cancel_cmp


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var d = IoUringDriver(sq_entries=4)
        _ = d^
        return True
    except:
        return False


# ── Multishot accept (io_uring-specific, IoUringDriver) ──────────────────────


struct MultishotTracker:
    """Records CQE flags for multishot accept verification."""

    var count: Int
    var saw_more: Int
    var saw_terminal: Int

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.count = 0
        self.saw_more = 0
        self.saw_terminal = 0

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that checks IORING_CQE_F_MORE flag."""
        var self_ptr = Pointer[MultishotTracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].count += 1
        if (flags & UInt32(IORING_CQE_F_MORE)) != 0:
            self_ptr[].saw_more += 1
        else:
            self_ptr[].saw_terminal += 1


def test_accept_multishot_produces_more_flag() raises:
    """Multishot accept produces CQEs with IORING_CQE_F_MORE flag set
    for each accepted connection while the op remains armed.
    """
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return

    comptime AF_INET6 = 10
    comptime SOCK_STREAM = 1

    # Listener on [::1]:0
    var listen_fd = external_call["socket", Int32](
        Int32(AF_INET6), Int32(SOCK_STREAM), Int32(0)
    )
    assert_true(Int(listen_fd) >= 0, "socket() failed")

    var addr = Array[UInt8, 28](fill=0)
    addr[0] = UInt8(AF_INET6)
    addr[8 + 15] = UInt8(1)  # ::1
    var addr_ptr = Pointer(to=addr).unsafe_bitcast[c_void]()
    var bind_res = external_call["bind", Int32](
        listen_fd, addr_ptr, Int32(28)
    )
    assert_equal(Int(bind_res), 0)
    var listen_res = external_call["listen", Int32](listen_fd, Int32(4))
    assert_equal(Int(listen_res), 0)

    # Read the ephemeral port back.
    var bound = Array[UInt8, 28](fill=0)
    var bound_len = Int32(28)
    var gn_res = external_call["getsockname", Int32](
        listen_fd,
        Pointer(to=bound).unsafe_bitcast[c_void](),
        Pointer(to=bound_len).unsafe_bitcast[Int32](),
    )
    assert_equal(Int(gn_res), 0)
    var port_hi = bound[2]
    var port_lo = bound[3]

    # Wire the multishot accept completion via IoUringDriver.
    var driver = IoUringDriver(sq_entries=8)
    var tracker = MultishotTracker()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var cmp = Completion(
        invoke=MultishotTracker.on_complete, context=ctx
    )
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )
    driver.submit_accept_multishot(RawHandle(Int(listen_fd)), cmp_ptr)

    # Open three clients in sequence and drain each accept CQE.
    for _ in range(3):
        var client_fd = external_call["socket", Int32](
            Int32(AF_INET6), Int32(SOCK_STREAM), Int32(0)
        )
        assert_true(Int(client_fd) >= 0)
        var dest = Array[UInt8, 28](fill=0)
        dest[0] = UInt8(AF_INET6)
        dest[2] = port_hi
        dest[3] = port_lo
        dest[8 + 15] = UInt8(1)
        var cr = external_call["connect", Int32](
            client_fd,
            Pointer(to=dest).unsafe_bitcast[c_void](),
            Int32(28),
        )
        assert_equal(Int(cr), 0)

        _ = driver.tick(wait=True)
        _ = external_call["close", Int32](client_fd)

    # We received at least three multishot CQEs. Each carried F_MORE since
    # the accept op is still armed.
    assert_true(
        tracker.saw_more >= 3,
        "expected >=3 F_MORE CQEs, got " + String(tracker.saw_more),
    )
    assert_equal(tracker.saw_terminal, 0)

    _ = external_call["close", Int32](listen_fd)
    _ = cmp


def main() raises:
    test_nop_single()
    test_nop_multiple()
    test_nop_batched()
    test_submit_cancel_cancels_pending_recv()
    test_accept_multishot_produces_more_flag()
    print("All completion loop tests passed.")
