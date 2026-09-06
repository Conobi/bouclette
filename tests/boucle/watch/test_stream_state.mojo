"""`_StreamState` termination policy driven by hand-fired completions.

No kernel: a pool state and a shared box are built on the heap with a
dead driver, and the stream's static callbacks are invoked with the
flag patterns the two drivers produce. Covers: delivery with MORE, benign
end (re-arm queued), error end (disarmed, error set, live released), the
Datagram view over a written buffer, drop while disarmed (leases back,
pool detached, key settled once), drop while armed (cancel requested)
followed by the kernel ending the op first, post-drop deliveries, and a
submitted cancel whose completion lands before or after the terminal.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true

from boucle.net.message import write_delivery_header
from boucle.socle.platform import (
    ECANCELED,
    ENOBUFS,
    IORING_CQE_BUFFER_SHIFT,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
)
from boucle.watch._callback import _KIND_BITS, _SlotLink
from boucle.watch._shared import _LoopShared
from boucle.watch.pool import _PoolState
from boucle.watch.stream import _StreamState, DatagramStream

comptime BUF_SIZE = 128
comptime BUF_COUNT = 4
comptime STREAM_KEY = (3 << _KIND_BITS) | 8


struct Fixture(Movable):
    """Heap-placed shared box, pool state and stream state with hand-made links."""

    var deferred: List[Int]
    var settle: List[Int]
    var pool_live: Int
    var stream_live: Int
    var shared: Pointer[_LoopShared, MutUntrackedOrigin]
    var pool: Pointer[_PoolState, MutUntrackedOrigin]
    var stream: Pointer[_StreamState, MutUntrackedOrigin]

    def __init__(out self):
        """Build the three states; the driver is marked dead so no driver call is made."""
        self.deferred = List[Int]()
        self.settle = List[Int]()
        self.pool_live = 1
        self.stream_live = 1
        var shared_mem = unsafe_alloc[_LoopShared](1)
        shared_mem.unsafe_write(
            _LoopShared(
                Pointer[List[Int], MutUntrackedOrigin](
                    unsafe_from_address=Int(Pointer(to=self.deferred))
                )
            )
        )
        self.shared = Pointer[_LoopShared, MutUntrackedOrigin](
            unsafe_from_address=Int(shared_mem)
        )
        self.shared[].driver_alive = False

        var mem = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(unsafe_alloc[UInt8](BUF_COUNT * BUF_SIZE))
        )
        for i in range(BUF_COUNT * BUF_SIZE):
            mem[unsafe_offset=i] = UInt8(0)
        var pool_mem = unsafe_alloc[_PoolState](1)
        pool_mem.unsafe_write(
            _PoolState(mem, BUF_SIZE, BUF_COUNT, UInt16(1), self.shared)
        )
        self.pool = Pointer[_PoolState, MutUntrackedOrigin](
            unsafe_from_address=Int(pool_mem)
        )
        var settle_ptr = Pointer[List[Int], MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self.settle))
        )
        self.pool[].bind(
            _SlotLink(
                (0 << _KIND_BITS) | 9,
                settle_ptr,
                Pointer[Int, MutUntrackedOrigin](
                    unsafe_from_address=Int(Pointer(to=self.pool_live))
                ),
            )
        )

        var stream_mem = unsafe_alloc[_StreamState](1)
        stream_mem.unsafe_write(
            _StreamState(Int32(-1), UInt16(1), 0, self.pool, self.shared)
        )
        self.stream = Pointer[_StreamState, MutUntrackedOrigin](
            unsafe_from_address=Int(stream_mem)
        )
        self.stream[].wire()
        self.stream[].bind(
            _SlotLink(
                STREAM_KEY,
                settle_ptr,
                Pointer[Int, MutUntrackedOrigin](
                    unsafe_from_address=Int(Pointer(to=self.stream_live))
                ),
            )
        )
        self.pool[].attach_stream()

    def __init__(out self, *, deinit move: Self):
        """Move constructor (the pointers keep pointing at heap boxes)."""
        self.deferred = move.deferred^
        self.settle = move.settle^
        self.pool_live = move.pool_live
        self.stream_live = move.stream_live
        self.shared = move.shared
        self.pool = move.pool
        self.stream = move.stream

    def fire(self, result: Int, flags: UInt32):
        """Invoke the stream's delivery callback as a driver would."""
        _StreamState._on_delivery(
            self.stream.unsafe_bitcast[NoneType](), result, flags
        )

    def fire_cancel(self, result: Int):
        """Invoke the stream's cancel callback as a driver would."""
        _StreamState._on_cancel_cb(
            self.stream.unsafe_bitcast[NoneType](), result, UInt32(0)
        )

    def drop_and_submit_cancel(self) raises:
        """Drop the handle while armed and pretend the flush submitted the cancel."""
        var handle = DatagramStream(self.stream)
        _ = handle^
        assert_true(self.stream[].cancel_requested)
        self.stream[].cancel_requested = False
        self.stream[].cancel_submitted = True
        self.stream[]._deferred_queued = False

    def write_datagram(self, bid: Int, payload: String):
        """Write a header + AF_INET name + payload into buffer `bid`."""
        var base = self.pool[].buffer_ptr(UInt16(bid))
        write_delivery_header(
            base,
            namelen=UInt32(16),
            controllen=UInt32(0),
            payloadlen=UInt32(payload.byte_length()),
            flags=UInt32(0),
        )
        base[unsafe_offset=16] = UInt8(2)  # AF_INET
        base[unsafe_offset=18] = UInt8(0x1F)  # port 8080 big-endian
        base[unsafe_offset=19] = UInt8(0x90)
        base[unsafe_offset=20] = UInt8(127)
        base[unsafe_offset=23] = UInt8(1)
        var bytes = payload.as_bytes()
        for i in range(len(bytes)):
            base[unsafe_offset=16 + 28 + i] = bytes[i]


def _delivery_flags(bid: Int, more: Bool) -> UInt32:
    """Build the flags both drivers put on a delivery."""
    var f = UInt32(IORING_CQE_F_BUFFER) | (
        UInt32(bid) << UInt32(IORING_CQE_BUFFER_SHIFT)
    )
    if more:
        f |= UInt32(IORING_CQE_F_MORE)
    return f


def test_delivery_benign_end_and_error() raises:
    """MORE enqueues; no-MORE queues a re-arm; a negative result disarms."""
    var fx = Fixture()
    fx.write_datagram(2, "hello")
    fx.fire(16 + 28 + 5, _delivery_flags(2, True))
    assert_equal(fx.shared[].stream_completions, 1)
    assert_equal(len(fx.stream[].deliveries), 1)
    assert_equal(fx.pool[].available, BUF_COUNT - 1)
    assert_true(fx.stream[].armed)
    assert_equal(len(fx.deferred), 0)

    fx.write_datagram(0, "hi")
    fx.fire(16 + 28 + 2, _delivery_flags(0, False))
    assert_equal(len(fx.stream[].deliveries), 2)
    assert_true(
        fx.stream[].armed, "benign end keeps the stream logically armed"
    )
    assert_true(fx.stream[].rearm_requested)
    assert_equal(len(fx.deferred), 1)
    assert_equal(fx.deferred[0], STREAM_KEY)
    fx.stream[].rearm_requested = False  # pretend the flush re-armed
    fx.stream[]._deferred_queued = False

    fx.fire(-Int(ENOBUFS), UInt32(0))
    assert_true(not fx.stream[].armed)
    assert_true(fx.stream[].error, "error() is set")
    assert_equal(fx.stream[].error.value().errno_value(), ENOBUFS)
    assert_equal(fx.stream_live, 0, "a disarmed stream is not in flight")
    assert_equal(len(fx.settle), 0, "held stream is not settled")

    # The handle pops deliveries oldest first and decodes them.
    var handle = DatagramStream(fx.stream)
    assert_equal(handle.pending(), 2)
    var first = handle.next()
    assert_true(first, "a delivery is queued")
    var dg = first.take()
    assert_equal(Int(dg.buffer.id()), 2)
    var payload = dg.payload()
    assert_equal(len(payload), 5)
    assert_equal(Int(payload[0]), ord("h"))
    assert_equal(dg.peer_family().id, UInt16(2))
    var peer = dg.peer_v4()
    assert_equal(Int(peer.port), 8080)
    assert_equal(String(peer.ip), "127.0.0.1")
    assert_true(not dg.truncated())
    var v6_raised = False
    try:
        _ = dg.peer_v6()
    except e:
        v6_raised = "EAFNOSUPPORT" in String(e)
    assert_true(v6_raised, "peer_v6 on a v4 name raises EAFNOSUPPORT")
    _ = dg^
    assert_equal(
        fx.pool[].available, BUF_COUNT - 1, "lease returned, one still queued"
    )

    # Drop while disarmed: queued lease back, pool detached, key settled once.
    _ = handle^
    assert_equal(fx.pool[].available, BUF_COUNT)
    assert_equal(fx.pool[].streams, 0)
    assert_equal(len(fx.settle), 1)
    assert_equal(fx.settle[0], STREAM_KEY)
    assert_true(fx.stream[].is_done())
    assert_true(fx.stream[].owner_dropped())
    assert_equal(fx.stream_live, 0)


def test_drop_while_armed_then_kernel_ends_first() raises:
    """Drop requests a cancel; a terminal before the cancel is submitted finishes the stream."""
    var fx = Fixture()
    fx.fire(16 + 28 + 1, _delivery_flags(1, True))
    var handle = DatagramStream(fx.stream)
    _ = handle^
    assert_true(fx.stream[]._owner_dropped)
    assert_true(
        fx.stream[].cancel_requested, "an armed stream asks for a cancel"
    )
    assert_equal(len(fx.deferred), 1)
    assert_equal(
        fx.pool[].available, BUF_COUNT, "queued leases return at once"
    )
    assert_equal(len(fx.settle), 0, "slot waits for the terminal completion")

    # A post-drop delivery is recycled, not queued, and counted as
    # internal: no handle can observe it, so `step()` must not report it.
    var streams_before = fx.shared[].stream_completions
    var internal_before = fx.shared[].internal_completions
    fx.fire(16 + 28 + 1, _delivery_flags(3, True))
    assert_equal(len(fx.stream[].deliveries), 0)
    assert_equal(fx.pool[].available, BUF_COUNT)
    assert_equal(fx.shared[].stream_completions, streams_before)
    assert_equal(fx.shared[].internal_completions, internal_before + 1)

    # The kernel ends the op (here with -ECANCELED) before any cancel was
    # submitted: nothing else will fire, so the stream finishes now.
    fx.fire(-Int(ECANCELED), UInt32(0))
    assert_true(
        not fx.stream[].cancel_requested, "unsubmitted cancel is dropped"
    )
    assert_equal(len(fx.settle), 1)
    assert_equal(fx.settle[0], STREAM_KEY)
    assert_equal(fx.stream_live, 0)
    assert_equal(fx.pool[].streams, 0)


def test_drop_with_rearm_pending_finishes_without_cancel() raises:
    """Nothing is in flight after a benign end, so the drop settles directly."""
    var fx = Fixture()
    fx.fire(16 + 28 + 1, _delivery_flags(0, False))
    assert_true(fx.stream[].rearm_requested)
    var handle = DatagramStream(fx.stream)
    _ = handle^
    assert_true(not fx.stream[].rearm_requested)
    assert_true(not fx.stream[].cancel_requested, "no op to cancel")
    assert_equal(len(fx.settle), 1)
    assert_equal(fx.stream_live, 0)
    assert_equal(fx.pool[].available, BUF_COUNT)
    assert_equal(fx.pool[].streams, 0)


def test_submitted_cancel_terminal_first() raises:
    """Terminal then cancel completion (epoll order): one key, one internal."""
    var fx = Fixture()
    fx.drop_and_submit_cancel()
    fx.fire(-Int(ECANCELED), UInt32(0))
    assert_true(not fx.stream[].armed)
    assert_true(not fx.stream[].is_done(), "waits for the cancel's completion")
    assert_equal(len(fx.settle), 0, "the terminal alone does not settle")
    assert_equal(fx.pool[].streams, 1, "pool still attached")
    fx.fire_cancel(0)
    assert_true(fx.stream[].is_done())
    assert_equal(len(fx.settle), 1)
    assert_equal(fx.settle[0], STREAM_KEY)
    assert_equal(fx.stream_live, 0)
    assert_equal(fx.pool[].streams, 0)
    assert_equal(fx.shared[].internal_completions, 1)
    assert_equal(fx.shared[].stream_completions, 1)


def test_submitted_cancel_cancel_first() raises:
    """Cancel completion then terminal (io_uring order): one key, one internal."""
    var fx = Fixture()
    fx.drop_and_submit_cancel()
    fx.fire_cancel(0)
    assert_true(fx.stream[].cancel_done)
    assert_true(fx.stream[].armed, "the operation is still in flight")
    assert_true(not fx.stream[].is_done())
    assert_equal(len(fx.settle), 0, "the cancel alone does not settle")
    assert_equal(fx.pool[].streams, 1, "pool still attached")
    fx.fire(-Int(ECANCELED), UInt32(0))
    assert_true(fx.stream[].is_done())
    assert_equal(len(fx.settle), 1)
    assert_equal(fx.settle[0], STREAM_KEY)
    assert_equal(fx.stream_live, 0)
    assert_equal(fx.pool[].streams, 0)
    assert_equal(fx.shared[].internal_completions, 1)
    assert_equal(fx.shared[].stream_completions, 1)


def main() raises:
    test_delivery_benign_end_and_error()
    test_drop_while_armed_then_kernel_ends_first()
    test_drop_with_rearm_pending_finishes_without_cancel()
    test_submitted_cancel_terminal_first()
    test_submitted_cancel_cancel_first()
    print("PASS: test_stream_state.mojo")
