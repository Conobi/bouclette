"""`_StreamState` termination policy driven by hand-fired completions.

No kernel: a pool state and a shared box are built on the heap with a
dead driver, and the stream's static callbacks are invoked with the
flag patterns the two drivers produce. Covers: delivery with MORE, benign
end (re-arm queued), error end (disarmed, error set, live released), the
Datagram view over a written buffer, drop while disarmed (leases back,
pool detached, key settled once), drop while armed (cancel requested)
followed by the kernel ending the op first, post-drop deliveries, a
submitted cancel whose completion lands before or after the terminal,
the rule that tells a full submission queue (retry the re-arm) apart
from a driver error (disarm), the MSG_CTRUNC flag, buffer ids past the
pool (dropped rather than dereferenced), an error carrying the MORE
flag (still terminal), a benign end after the drop, a delivery without
a buffer id, a dropped pool waiting for its last stream before its
key follows the stream's onto the settle queue, and a deferred cancel
the driver refuses for a reason other than a full queue (the stream
gives up on cancelling, stays armed so its slot is never settled while
the kernel may still write it, and a terminal that arrives on its own
settles it once).

Neither real driver can refuse a cancel that way, so the last case is
driven through the decision step `flush_deferred` takes on such a
refusal, not through a driver double.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true

from boucle.net.message import write_delivery_header
from boucle.net.options import AddrFamily
from boucle.socle.platform import (
    EAGAIN,
    EBADF,
    ECANCELED,
    ENOBUFS,
    EOPNOTSUPP,
    IORING_CQE_BUFFER_SHIFT,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    MSG_CTRUNC,
    MSG_TRUNC,
)
from boucle.watch._callback import _KIND_BITS, _SlotLink
from boucle.watch._shared import _LoopShared
from boucle.watch.pool import _PoolState, LeasedBuffer
from boucle.watch.stream import (
    _is_queue_full,
    _StreamState,
    Datagram,
    DatagramStream,
)

comptime BUF_SIZE = 128
comptime BUF_COUNT = 4
comptime STREAM_KEY = (3 << _KIND_BITS) | 8
comptime POOL_KEY = (0 << _KIND_BITS) | 9


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

    def write_datagram(self, bid: Int, payload: String, flags: UInt32 = 0):
        """Write a header + AF_INET name + payload into buffer `bid`."""
        var base = self.pool[].buffer_ptr(UInt16(bid))
        write_delivery_header(
            base,
            namelen=UInt32(16),
            controllen=UInt32(0),
            payloadlen=UInt32(payload.byte_length()),
            flags=flags,
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
    assert_equal(dg.count(), 5, "count() is the full datagram length")
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
    """Terminal then cancel completion (epoll order): one key, both internal.

    The pool's handle is dropped first: a pool with a stream attached
    waits for that stream, and its key follows the stream's.
    """
    var fx = Fixture()
    fx.drop_and_submit_cancel()
    fx.pool[].mark_owner_dropped()
    assert_true(not fx.pool[]._queued, "a referenced pool does not settle")
    assert_equal(len(fx.settle), 0)
    fx.fire(-Int(ECANCELED), UInt32(0))
    assert_true(not fx.stream[].armed)
    assert_true(not fx.stream[].is_done(), "waits for the cancel's completion")
    assert_equal(len(fx.settle), 0, "the terminal alone does not settle")
    assert_equal(fx.pool[].streams, 1, "pool still attached")
    assert_true(not fx.pool[]._queued)
    fx.fire_cancel(0)
    assert_true(fx.stream[].is_done())
    assert_equal(len(fx.settle), 2, "the stream's key, then the pool's")
    assert_equal(fx.settle[0], STREAM_KEY)
    assert_equal(fx.settle[1], POOL_KEY)
    assert_true(fx.pool[]._queued)
    assert_equal(fx.pool_live, 0)
    assert_equal(fx.stream_live, 0)
    assert_equal(fx.pool[].streams, 0)
    assert_equal(
        fx.shared[].internal_completions,
        2,
        "the terminal of a dropped stream and the cancel are both internal",
    )
    assert_equal(fx.shared[].stream_completions, 0)


def test_submitted_cancel_cancel_first() raises:
    """Cancel completion then terminal (io_uring order): one key, both internal.

    As above, the pool's handle is dropped first and the pool's key
    follows the stream's once the terminal lands.
    """
    var fx = Fixture()
    fx.drop_and_submit_cancel()
    fx.pool[].mark_owner_dropped()
    assert_true(not fx.pool[]._queued, "a referenced pool does not settle")
    fx.fire_cancel(0)
    assert_true(fx.stream[].cancel_done)
    assert_true(fx.stream[].armed, "the operation is still in flight")
    assert_true(not fx.stream[].is_done())
    assert_equal(len(fx.settle), 0, "the cancel alone does not settle")
    assert_equal(fx.pool[].streams, 1, "pool still attached")
    assert_true(not fx.pool[]._queued)
    fx.fire(-Int(ECANCELED), UInt32(0))
    assert_true(fx.stream[].is_done())
    assert_equal(len(fx.settle), 2, "the stream's key, then the pool's")
    assert_equal(fx.settle[0], STREAM_KEY)
    assert_equal(fx.settle[1], POOL_KEY)
    assert_true(fx.pool[]._queued)
    assert_equal(fx.pool_live, 0)
    assert_equal(fx.stream_live, 0)
    assert_equal(fx.pool[].streams, 0)
    assert_equal(
        fx.shared[].internal_completions,
        2,
        "the terminal of a dropped stream and the cancel are both internal",
    )
    assert_equal(fx.shared[].stream_completions, 0)


def test_queue_full_is_told_apart_from_a_driver_error() raises:
    """Only the driver's EAGAIN (queue still full after a flush) means retry."""
    assert_true(_is_queue_full(Error(String(-EAGAIN))))
    assert_true(not _is_queue_full(Error(String(-EOPNOTSUPP))))
    assert_true(not _is_queue_full(Error(String(-EBADF))))
    assert_true(not _is_queue_full(Error("not an errno")))


def test_control_truncated_reads_msg_ctrunc() raises:
    """A header carrying MSG_CTRUNC reports control truncation, not payload truncation."""
    var fx = Fixture()
    fx.write_datagram(1, "x", flags=UInt32(MSG_CTRUNC))
    fx.fire(16 + 28 + 1, _delivery_flags(1, True))
    var handle = DatagramStream(fx.stream)
    var first = handle.next()
    var dg = first.take()
    assert_true(dg.control_truncated(), "MSG_CTRUNC is reported")
    assert_true(not dg.truncated(), "MSG_TRUNC is not")
    _ = dg^
    _ = handle^


def test_truncated_reads_msg_trunc() raises:
    """A header carrying MSG_TRUNC reports payload truncation, not control truncation."""
    var fx = Fixture()
    fx.write_datagram(1, "x", flags=UInt32(MSG_TRUNC))
    fx.fire(16 + 28 + 1, _delivery_flags(1, True))
    var handle = DatagramStream(fx.stream)
    var first = handle.next()
    var dg = first.take()
    assert_true(dg.truncated(), "MSG_TRUNC is reported")
    assert_true(not dg.control_truncated(), "MSG_CTRUNC is not")
    _ = dg^
    _ = handle^


def test_rearm_refused_retries_only_a_full_queue() raises:
    """A re-arm refused with EAGAIN stays requested and re-queues; any other errno disarms."""
    var fx = Fixture()
    fx.stream[].rearm_requested = True
    fx.stream[]._deferred_queued = False
    fx.stream[]._rearm_refused(Error(String(-EAGAIN)))
    assert_true(fx.stream[].rearm_requested, "queue full: still requested")
    assert_true(fx.stream[].armed, "queue full: still armed")
    assert_true(not fx.stream[].error, "queue full: no error")
    assert_equal(len(fx.deferred), 1, "queue full: key re-queued")
    assert_equal(fx.deferred[0], STREAM_KEY)

    fx.deferred.clear()
    fx.stream[]._deferred_queued = False
    fx.stream[]._rearm_refused(Error(String(-EBADF)))
    assert_true(not fx.stream[].rearm_requested, "driver error: dropped")
    assert_true(not fx.stream[].armed, "driver error: disarmed")
    assert_equal(fx.stream[].error.value().errno_value(), EBADF)
    assert_equal(len(fx.deferred), 0, "driver error: nothing re-queued")
    assert_equal(fx.stream_live, 0, "driver error: no longer counted live")


def test_out_of_range_buffer_id_is_ignored() raises:
    """A buffer id at or past `count` is never dereferenced: the delivery is dropped."""
    var fx = Fixture()
    assert_equal(
        Int(fx.pool[].buffer_ptr(UInt16(BUF_COUNT))),
        0,
        "buffer_ptr is null past the last buffer",
    )
    assert_true(Int(fx.pool[].buffer_ptr(UInt16(BUF_COUNT - 1))) != 0)

    var streams_before = fx.shared[].stream_completions
    var internal_before = fx.shared[].internal_completions
    fx.fire(16 + 28 + 1, _delivery_flags(BUF_COUNT, True))
    assert_equal(len(fx.stream[].deliveries), 0, "not queued")
    assert_equal(fx.pool[].available, BUF_COUNT, "no lease was taken")
    assert_equal(fx.shared[].stream_completions, streams_before)
    assert_equal(fx.shared[].internal_completions, internal_before + 1)
    assert_true(fx.stream[].armed, "the stream stays armed")

    # A benign end with a bad id still queues the re-arm.
    fx.fire(16 + 28 + 1, _delivery_flags(BUF_COUNT + 7, False))
    assert_equal(len(fx.stream[].deliveries), 0)
    assert_equal(fx.pool[].available, BUF_COUNT)
    assert_true(fx.stream[].rearm_requested, "the op ended: re-arm queued")
    assert_equal(fx.shared[].internal_completions, internal_before + 2)

    # Returning an out-of-range id is a no-op, and a lease over one views nothing.
    fx.pool[].return_lease(UInt16(BUF_COUNT))
    assert_equal(fx.pool[].available, BUF_COUNT)
    var stray = LeasedBuffer(fx.pool, UInt16(BUF_COUNT))
    assert_equal(len(stray.bytes()), 0, "no bytes for an id past the pool")
    _ = stray^
    assert_equal(fx.pool[].available, BUF_COUNT, "its return changed nothing")

    # A Datagram over such a lease decodes as empty rather than reading
    # past a buffer it does not have.
    var empty = Datagram(LeasedBuffer(fx.pool, UInt16(BUF_COUNT)), UInt32(0), 0)
    assert_true(empty.peer_family() == AddrFamily.UNSPEC, "no name: UNSPEC")
    assert_true(not empty.truncated())
    assert_true(not empty.control_truncated())
    assert_equal(len(empty.payload()), 0)
    assert_equal(empty.count(), 0)
    _ = empty^
    assert_equal(fx.pool[].available, BUF_COUNT)


def test_error_with_more_flag_is_terminal() raises:
    """A negative result is terminal even with the MORE flag set."""
    var fx = Fixture()
    fx.fire(-Int(ENOBUFS), UInt32(IORING_CQE_F_MORE))
    assert_true(not fx.stream[].armed, "disarmed despite MORE")
    assert_equal(fx.stream[].error.value().errno_value(), ENOBUFS)
    assert_equal(fx.stream_live, 0)
    assert_equal(fx.shared[].stream_completions, 1)
    assert_equal(len(fx.settle), 0, "held: not settled")


def test_benign_end_after_drop_finishes_the_stream() raises:
    """Result >= 0 without MORE on a dropped stream recycles and settles."""
    var fx = Fixture()
    var handle = DatagramStream(fx.stream)
    _ = handle^
    assert_true(fx.stream[].cancel_requested)
    fx.fire(16 + 28 + 1, _delivery_flags(1, False))
    assert_equal(len(fx.stream[].deliveries), 0, "recycled, not queued")
    assert_equal(fx.pool[].available, BUF_COUNT)
    assert_equal(fx.shared[].internal_completions, 1, "unobservable")
    assert_equal(fx.shared[].stream_completions, 0)
    assert_true(not fx.stream[].cancel_requested, "nothing left to cancel")
    assert_true(not fx.stream[].rearm_requested, "a dropped stream never re-arms")
    assert_equal(len(fx.settle), 1)
    assert_equal(fx.settle[0], STREAM_KEY)
    assert_equal(fx.stream_live, 0)
    assert_equal(fx.pool[].streams, 0)


def test_delivery_without_a_buffer_id_queues_nothing() raises:
    """Result >= 0 with no buffer flag leases nothing; the end still re-arms."""
    var fx = Fixture()
    fx.fire(0, UInt32(IORING_CQE_F_MORE))
    assert_equal(len(fx.stream[].deliveries), 0)
    assert_equal(fx.pool[].available, BUF_COUNT)
    assert_equal(fx.shared[].stream_completions, 1)
    assert_true(fx.stream[].armed)
    assert_true(not fx.stream[].rearm_requested)
    fx.fire(0, UInt32(0))
    assert_equal(len(fx.stream[].deliveries), 0)
    assert_equal(fx.pool[].available, BUF_COUNT)
    assert_equal(fx.shared[].stream_completions, 2)
    assert_true(fx.stream[].rearm_requested, "benign end queues the re-arm")
    assert_equal(len(fx.deferred), 1)


def test_refused_cancel_keeps_the_slot_until_the_op_ends() raises:
    """A cancel refused for a genuine error stops retrying but never settles by itself.

    The multishot may still be armed kernel-side, so settling here
    would let a later completion write into a freed slot. The state
    stays armed and undone; a terminal that lands on its own finishes
    the stream exactly once.
    """
    var fx = Fixture()
    var handle = DatagramStream(fx.stream)
    _ = handle^
    assert_true(fx.stream[].cancel_requested)
    fx.deferred.clear()  # the flush popped the key before calling the state
    fx.stream[]._deferred_queued = False
    fx.stream[]._cancel_refused()
    assert_true(not fx.stream[].cancel_requested, "no further retry")
    assert_true(not fx.stream[].cancel_submitted)
    assert_true(fx.stream[].cancel_failed)
    assert_true(fx.stream[].armed, "the op may still be in flight")
    assert_true(not fx.stream[].is_done(), "the slot is not reclaimable")
    assert_equal(len(fx.settle), 0, "nothing settles on the refusal")
    assert_equal(len(fx.deferred), 0, "the key is not re-queued either")
    assert_equal(fx.stream_live, 1, "still counted in flight")

    # A delivery that lands afterwards is recycled, and the terminal
    # settles the slot exactly once.
    fx.fire(16 + 28 + 1, _delivery_flags(2, True))
    assert_equal(fx.pool[].available, BUF_COUNT)
    assert_equal(len(fx.settle), 0)
    fx.fire(-Int(ECANCELED), UInt32(0))
    assert_true(fx.stream[].is_done())
    assert_equal(len(fx.settle), 1)
    assert_equal(fx.settle[0], STREAM_KEY)
    assert_equal(fx.stream_live, 0)
    assert_equal(fx.pool[].streams, 0)


def main() raises:
    test_refused_cancel_keeps_the_slot_until_the_op_ends()
    test_error_with_more_flag_is_terminal()
    test_benign_end_after_drop_finishes_the_stream()
    test_delivery_without_a_buffer_id_queues_nothing()
    test_control_truncated_reads_msg_ctrunc()
    test_truncated_reads_msg_trunc()
    test_rearm_refused_retries_only_a_full_queue()
    test_out_of_range_buffer_id_is_ignored()
    test_queue_full_is_told_apart_from_a_driver_error()
    test_delivery_benign_end_and_error()
    test_drop_while_armed_then_kernel_ends_first()
    test_drop_with_rearm_pending_finishes_without_cancel()
    test_submitted_cancel_terminal_first()
    test_submitted_cancel_cancel_first()
    print("PASS: test_stream_state.mojo")
