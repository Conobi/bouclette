"""Multishot recvmsg emulated over epoll with provided buffers.

One epoll wake drains the socket: each datagram lands in a free buffer of
the group behind a 16-byte delivery header, and the completion fires with
IORING_CQE_F_BUFFER | IORING_CQE_F_MORE and the buffer id in the high 16
bits. When the group runs dry the op ends with -ENOBUFS and flags 0; a
cancel ends it with -ECANCELED and flags 0. The op stays registered while
deliveries fire and is gone once a terminal completion fired. Returned
buffers are handed out again, an oversized datagram reports MSG_TRUNC with
its full length, a one-shot sendmsg on the same fd keeps working while
the multishot op is armed, and a socket that reports readable forever
without ever yielding a datagram (read shutdown, or a pending socket
error) ends the op with that errno instead of spinning the driver.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.drivers.epoll_completion import EpollCompletionDriver
from boucle.net.addr import SocketAddrV4
from boucle.net.message import DELIVERY_HEADER_LEN, DeliveryHeader
from boucle.net.options import Shutdown
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.socle.linux.raw import (
    syscall,
    iovec,
    msghdr,
    __NR_fcntl,
    ECANCELED,
    ECONNREFUSED,
    ECONNRESET,
    ENOBUFS,
    IORING_CQE_BUFFER_SHIFT,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    MSG_TRUNC,
)

comptime BUF_COUNT = 4
comptime BUF_SIZE = 256
comptime NAME_CAP = 28
comptime GROUP = 5


struct Tracker:
    """Records every completion fired on one Completion."""

    var count: Int
    var results: Array[Int, 16]
    var flags: Array[UInt32, 16]

    def __init__(out self):
        """Construct an empty tracker."""
        self.count = 0
        self.results = Array[Int, 16](fill=0)
        self.flags = Array[UInt32, 16](fill=UInt32(0))

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """Store result and flags at the next index."""
        var self_ptr = Pointer[Tracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        var i = self_ptr[].count
        if i < 16:
            self_ptr[].results[i] = result
            self_ptr[].flags[i] = flags
        self_ptr[].count += 1


struct ReturningTracker:
    """Counts deliveries and hands every buffer straight back to the driver.

    Models a consumer that never holds a lease, the shape under which an
    unbounded drain loop would never run out of buffers.
    """

    var driver: Pointer[EpollCompletionDriver, MutUntrackedOrigin]
    var count: Int
    var last_flags: UInt32

    def __init__(out self, ref driver: EpollCompletionDriver):
        """Bind the tracker to `driver` with a zero count."""
        self.driver = Pointer[EpollCompletionDriver, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=driver))
        )
        self.count = 0
        self.last_flags = UInt32(0)

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """Count the delivery and return its buffer to GROUP."""
        var self_ptr = Pointer[ReturningTracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].count += 1
        self_ptr[].last_flags = flags
        if (flags & UInt32(IORING_CQE_F_BUFFER)) != 0:
            self_ptr[].driver[].return_buffer(
                UInt16(GROUP), UInt16(flags >> UInt32(IORING_CQE_BUFFER_SHIFT))
            )


def _completion(ref tracker: Tracker) -> Completion:
    """Wire a Completion onto `tracker`."""
    return Completion(
        invoke=Tracker.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=tracker))
        ),
    )


def _ptr[T: AnyType](ref value: T) -> Pointer[T, MutUntrackedOrigin]:
    """Untracked pointer to a caller-owned value."""
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=value))
    )


def _alloc_group(mut driver: EpollCompletionDriver) raises -> Pointer[
    UInt8, MutUntrackedOrigin
]:
    """Allocate and zero BUF_COUNT buffers of BUF_SIZE and register them as GROUP."""
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](BUF_COUNT * BUF_SIZE))
    )
    for i in range(BUF_COUNT * BUF_SIZE):
        mem[unsafe_offset=i] = UInt8(0)
    driver.register_buffer_group(mem, UInt32(BUF_SIZE), BUF_COUNT, UInt16(GROUP))
    return mem


def _send(ref sender: Socket, ref to: SocketAddrV4, tag: UInt8) raises:
    """Send a 4-byte datagram 'D', tag, 0x55, '!' to `to`."""
    var payload = List[UInt8](length=4, fill=0)
    payload[0] = UInt8(ord("D"))
    payload[1] = tag
    payload[2] = UInt8(0x55)
    payload[3] = UInt8(ord("!"))
    assert_equal(sender.send_to(Span(payload), to), 4)


def _tick_until(
    mut driver: EpollCompletionDriver, ref tracker: Tracker, count: Int, what: String
) raises:
    """Tick (blocking) until `tracker.count >= count`, bounded at 50 ticks.

    Each tick waits at most one second, so a stalled delivery fails the
    test with `what` instead of hanging it: with no timer armed, an
    unbounded `tick(wait=True)` would never return and the tick bound
    would never be checked.

    The count is read through an untracked pointer: the driver writes it
    from a callback the compiler cannot see, so a plain `ref` read could
    legally be hoisted out of the loop.
    """
    var seen = Pointer[Tracker, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var ticks = 0
    while seen[].count < count:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 50, what)


comptime F_GETFD = 1


def _fd_is_open(fd: Int32) -> Bool:
    """Return True if `fd` names an open descriptor (fcntl F_GETFD succeeds)."""
    return syscall[__NR_fcntl, Scalar[DType.int64]](fd, Int32(F_GETFD), Int32(0)) >= 0


def _armed_dup(ref driver: EpollCompletionDriver, target: Pointer[Completion, MutUntrackedOrigin]) -> Int32:
    """Return the driver-owned dup of the active op whose completion is `target`, or -1."""
    for i in range(driver._state[].pool.capacity()):
        var op = driver._state[].pool.slot_ptr(i)
        if op[].active and Int(op[].completion) == Int(target):
            return op[].dup_fd
    return Int32(-1)


def _buffer_id(flags: UInt32) -> Int:
    """Extract the buffer id from delivery flags."""
    return Int(flags >> UInt32(IORING_CQE_BUFFER_SHIFT))


def _check_delivery(
    mem: Pointer[UInt8, MutUntrackedOrigin],
    result: Int,
    flags: UInt32,
    sender_port: Int,
) raises -> Int:
    """Check one 4-byte delivery's flags, result and header; return its tag."""
    assert_true((flags & UInt32(IORING_CQE_F_BUFFER)) != 0, "BUFFER flag")
    assert_true((flags & UInt32(IORING_CQE_F_MORE)) != 0, "MORE flag")
    var bid = _buffer_id(flags)
    assert_true(bid < BUF_COUNT, "buffer id in range")
    assert_equal(result, DELIVERY_HEADER_LEN + NAME_CAP + 4)
    var buf = Span[UInt8, MutUntrackedOrigin](
        unsafe_ptr=mem.unsafe_offset(bid * BUF_SIZE), length=BUF_SIZE
    )
    var hdr = DeliveryHeader.parse(buf, name_capacity=NAME_CAP, control_capacity=0)
    assert_equal(Int(hdr.namelen()), 16, "sockaddr_in written")
    assert_equal(Int(hdr.controllen()), 0)
    assert_equal(Int(hdr.payloadlen()), 4)
    assert_equal(Int(hdr.flags()), 0)
    var name = hdr.name()
    assert_equal(Int(name[0]), 2, "AF_INET")
    assert_equal((Int(name[2]) << 8) | Int(name[3]), sender_port)
    var payload = hdr.payload()
    assert_equal(len(payload), 4)
    assert_equal(Int(payload[0]), ord("D"))
    assert_equal(Int(payload[2]), 0x55)
    assert_equal(Int(payload[3]), ord("!"))
    return Int(payload[1])


def test_deliveries_then_enobufs() raises:
    """Three datagrams give three deliveries; two more exhaust four buffers and end the op."""
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var sender_port = Int(sender.local_addr_v4().port)

    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    tmpl.msg_controllen = UInt64(0)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    var slots_before = driver._state[].pool.free_count()

    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )
    assert_equal(
        driver._state[].pool.free_count(), slots_before - 1, "op holds a slot"
    )

    for tag in range(3):
        _send(sender, to, UInt8(tag))
    _tick_until(driver, tracker, 3, "deliveries did not arrive")
    assert_equal(tracker.count, 3)
    assert_equal(
        driver._state[].pool.free_count(),
        slots_before - 1,
        "multishot op stays registered after deliveries",
    )

    var seen = List[Bool](length=3, fill=False)
    var ids = List[Bool](length=BUF_COUNT, fill=False)
    for i in range(3):
        var tag = _check_delivery(
            mem, tracker.results[i], tracker.flags[i], sender_port
        )
        assert_true(not seen[tag], "each datagram delivered once")
        seen[tag] = True
        var bid = _buffer_id(tracker.flags[i])
        assert_true(not ids[bid], "distinct buffer ids")
        ids[bid] = True

    # The template is read, never written past what recvmsg does.
    assert_equal(Int(tmpl.msg_namelen), NAME_CAP)
    assert_equal(Int(tmpl.msg_controllen), 0)
    assert_equal(Int(tmpl.msg_name), 0)
    assert_equal(Int(tmpl.msg_iov), 0)

    # Nothing returned: one buffer left. Two more datagrams -> one
    # delivery with MORE, then -ENOBUFS with flags 0, op deregistered.
    _send(sender, to, UInt8(7))
    _send(sender, to, UInt8(8))
    _tick_until(driver, tracker, 5, "ENOBUFS path did not fire")
    assert_equal(tracker.count, 5)
    assert_true((tracker.flags[3] & UInt32(IORING_CQE_F_MORE)) != 0)
    assert_equal(tracker.results[4], -Int(ENOBUFS))
    assert_equal(Int(tracker.flags[4]), 0, "terminal completion carries no flags")
    assert_equal(
        driver._state[].pool.free_count(), slots_before, "slot freed at terminal"
    )
    assert_equal(len(driver._state[].groups[0].free), 0)

    # The op is gone: a further datagram never fires anything.
    _send(sender, to, UInt8(9))
    assert_equal(driver.tick(wait=False), 0)
    assert_equal(tracker.count, 5)

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = cmp
    _ = tmpl


def test_returned_buffers_are_reused() raises:
    """Buffers handed back with return_buffer serve later deliveries."""
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var sender_port = Int(sender.local_addr_v4().port)

    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )

    # Round 1: three of the four buffers consumed; one stays free so the
    # drain loop does not end the op with ENOBUFS (see the exact-fill test).
    comptime ROUND = BUF_COUNT - 1
    for tag in range(ROUND):
        _send(sender, to, UInt8(tag))
    _tick_until(driver, tracker, ROUND, "round 1 did not arrive")
    assert_equal(tracker.count, ROUND)
    assert_equal(len(driver._state[].groups[0].free), 1)
    var returned = List[Bool](length=BUF_COUNT, fill=False)
    for i in range(ROUND):
        _ = _check_delivery(mem, tracker.results[i], tracker.flags[i], sender_port)
        var bid = _buffer_id(tracker.flags[i])
        driver.return_buffer(UInt16(GROUP), UInt16(bid))
        returned[bid] = True
    assert_equal(len(driver._state[].groups[0].free), BUF_COUNT)

    # Round 2: the returned ids come back (they sit on top of the free
    # list), still with MORE, op still armed.
    var slots_armed = driver._state[].pool.free_count()
    for tag in range(ROUND):
        _send(sender, to, UInt8(10 + tag))
    _tick_until(driver, tracker, 2 * ROUND, "round 2 did not arrive")
    assert_equal(tracker.count, 2 * ROUND)
    var seen = List[Bool](length=BUF_COUNT, fill=False)
    for i in range(ROUND, 2 * ROUND):
        var tag = _check_delivery(
            mem, tracker.results[i], tracker.flags[i], sender_port
        )
        assert_true(tag >= 10 and tag < 10 + ROUND, "round 2 payload")
        var bid = _buffer_id(tracker.flags[i])
        assert_true(returned[bid], "reused a returned id")
        assert_true(not seen[bid], "distinct ids in round 2")
        seen[bid] = True
    assert_equal(len(driver._state[].groups[0].free), 1)
    assert_equal(driver._state[].pool.free_count(), slots_armed, "still armed")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = cmp
    _ = tmpl


def test_exact_fill_ends_with_enobufs() raises:
    """Filling every buffer in one wake ends the op with -ENOBUFS even on an empty socket.

    The drain loop asks for a buffer before it asks the socket, so a round
    that consumes the last free id terminates right away. The stream layer
    surfaces this as `error()` and the caller re-arms after returning
    leases, which is why this is the documented cadence rather than a bug.
    """
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))

    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    var slots_before = driver._state[].pool.free_count()
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )
    for tag in range(BUF_COUNT):
        _send(sender, to, UInt8(tag))
    _tick_until(driver, tracker, BUF_COUNT + 1, "exact fill did not terminate")
    assert_equal(tracker.count, BUF_COUNT + 1)
    for i in range(BUF_COUNT):
        assert_true((tracker.flags[i] & UInt32(IORING_CQE_F_MORE)) != 0)
    assert_equal(tracker.results[BUF_COUNT], -Int(ENOBUFS))
    assert_equal(Int(tracker.flags[BUF_COUNT]), 0)
    assert_equal(driver._state[].pool.free_count(), slots_before, "slot freed")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = cmp
    _ = tmpl


def test_cancel_ends_multishot_with_ecanceled() raises:
    """`cancel()` on an armed multishot fires -ECANCELED (flags 0) and frees the slot."""
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var target = Tracker()
    var target_cmp = _completion(target)
    var cancel = Tracker()
    var cancel_cmp = _completion(cancel)
    var slots_before = driver._state[].pool.free_count()

    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(target_cmp),
    )
    driver.cancel(_ptr(target_cmp), _ptr(cancel_cmp))
    var dispatched = driver.tick(wait=False)
    assert_equal(dispatched, 2)
    assert_equal(target.count, 1)
    assert_equal(target.results[0], -Int(ECANCELED))
    assert_equal(Int(target.flags[0]), 0)
    assert_equal(cancel.count, 1)
    assert_equal(cancel.results[0], 0)
    assert_equal(driver._state[].pool.free_count(), slots_before)
    assert_equal(len(driver._state[].groups[0].free), BUF_COUNT, "no buffer taken")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    _ = target_cmp
    _ = cancel_cmp
    _ = tmpl


def test_deliveries_per_tick_are_bounded() raises:
    """A consumer that returns every buffer gets at most 32 deliveries per tick; the rest follow.

    Forty datagrams wait on the socket before the first tick. Without a
    bound the drain loop would deliver all of them in one tick, and a
    peer that keeps sending would keep it there, starving timers and
    every other descriptor.
    """
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var tracker = ReturningTracker(driver)
    var cmp = Completion(
        invoke=ReturningTracker.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=tracker))
        ),
    )
    var slots_before = driver._state[].pool.free_count()
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )
    comptime TOTAL = 40
    for tag in range(TOTAL):
        _send(sender, to, UInt8(tag))

    var seen = Pointer[ReturningTracker, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var first = driver.tick(wait=True, timeout_ms=1000)
    assert_equal(first, seen[].count)
    assert_true(first > 0, "the first tick delivered something")
    assert_true(first <= 32, "at most 32 deliveries in one tick")
    assert_true(
        (seen[].last_flags & UInt32(IORING_CQE_F_MORE)) != 0,
        "the op is still armed after the bounded tick",
    )
    assert_equal(
        driver._state[].pool.free_count(), slots_before - 1, "slot still held"
    )

    # The remainder arrives on later ticks without any new datagram.
    var ticks = 0
    while seen[].count < TOTAL:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 10, "the remaining datagrams never arrived")
    assert_equal(seen[].count, TOTAL)
    assert_true(
        (seen[].last_flags & UInt32(IORING_CQE_F_MORE)) != 0, "still armed at the end"
    )
    assert_equal(driver._state[].pool.free_count(), slots_before - 1)
    assert_equal(len(driver._state[].groups[0].free), BUF_COUNT, "every buffer returned")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = cmp
    _ = tmpl


def test_unregistered_group_ends_multishot_with_enobufs() raises:
    """Unregistering the group under an armed op ends it with -ENOBUFS on the next datagram."""
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    var slots_before = driver._state[].pool.free_count()
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )
    var dup = _armed_dup(driver, _ptr(cmp))
    assert_true(dup >= 0, "armed op holds a dup")

    driver.unregister_buffer_group(UInt16(GROUP))
    _send(sender, to, UInt8(1))
    _tick_until(driver, tracker, 1, "terminal completion did not fire")
    assert_equal(tracker.count, 1)
    assert_equal(tracker.results[0], -Int(ENOBUFS))
    assert_equal(Int(tracker.flags[0]), 0, "terminal completion carries no flags")
    assert_equal(driver._state[].pool.free_count(), slots_before, "slot freed")
    assert_true(not _fd_is_open(dup), "dup closed at the terminal")
    for i in range(BUF_COUNT * BUF_SIZE):
        assert_equal(Int(mem[unsafe_offset=i]), 0, "no buffer of the gone group was written")

    # The datagram is still queued on the socket, untouched.
    var inbox = List[UInt8](length=16, fill=0)
    assert_equal(receiver.recv_from_v4(Span(inbox))[0], 4)

    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = cmp
    _ = tmpl


def test_control_messages_are_delivered() raises:
    """With a 64-byte control capacity the delivery carries the sender's TOS record after the name."""
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.set_recv_tos()
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    sender.set_tos(UInt8(2))
    var sender_port = Int(sender.local_addr_v4().port)

    comptime CTRL_CAP = 64
    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    tmpl.msg_controllen = UInt64(CTRL_CAP)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )
    _send(sender, to, UInt8(6))
    _tick_until(driver, tracker, 1, "delivery with control did not arrive")
    assert_equal(tracker.count, 1)
    var bid = _buffer_id(tracker.flags[0])
    var buf = Span[UInt8, MutUntrackedOrigin](
        unsafe_ptr=mem.unsafe_offset(bid * BUF_SIZE), length=BUF_SIZE
    )
    var hdr = DeliveryHeader.parse(
        buf, name_capacity=NAME_CAP, control_capacity=CTRL_CAP
    )
    assert_true(Int(hdr.controllen()) > 0, "a control record was written")
    assert_true(Int(hdr.controllen()) <= CTRL_CAP, "it fits the capacity")
    assert_equal(Int(hdr.namelen()), 16)
    var name = hdr.name()
    assert_equal(Int(name[0]), 2, "AF_INET")
    assert_equal((Int(name[2]) << 8) | Int(name[3]), sender_port, "peer port")
    assert_equal(Int(hdr.payloadlen()), 4)
    assert_equal(
        tracker.results[0], DELIVERY_HEADER_LEN + NAME_CAP + CTRL_CAP + 4
    )
    var mark = hdr.control().ecn()
    assert_true(Bool(mark), "an IP_TOS record is in the control area")
    assert_equal(Int(mark.value()), 2)
    assert_equal(Int(hdr.payload()[1]), 6)

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = cmp
    _ = tmpl


def test_cancel_after_close_releases_slot_and_dup() raises:
    """Closing the socket under an armed multishot, then cancelling, frees the slot and closes the dup."""
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var target = Tracker()
    var target_cmp = _completion(target)
    var cancel = Tracker()
    var cancel_cmp = _completion(cancel)
    var slots_before = driver._state[].pool.free_count()

    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(target_cmp),
    )
    var dup = _armed_dup(driver, _ptr(target_cmp))
    assert_true(dup >= 0, "the driver holds its own dup of the socket")
    assert_true(Int(dup) != Int(receiver.raw()), "the dup is a distinct number")
    assert_true(_fd_is_open(dup), "the dup is open while armed")

    receiver.close()
    assert_true(_fd_is_open(dup), "closing the user's fd leaves the dup open")

    driver.cancel(_ptr(target_cmp), _ptr(cancel_cmp))
    assert_equal(driver.tick(wait=False), 2)
    assert_equal(target.results[0], -Int(ECANCELED))
    assert_equal(cancel.results[0], 0)
    assert_equal(driver._state[].pool.free_count(), slots_before, "slot freed")
    assert_true(not _fd_is_open(dup), "the dup is closed at detach")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    _ = target_cmp
    _ = cancel_cmp
    _ = tmpl


def test_truncation_reports_full_length() raises:
    """A datagram larger than the payload room is cut, flagged MSG_TRUNC and sized in full."""
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))

    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )

    comptime ROOM = BUF_SIZE - DELIVERY_HEADER_LEN - NAME_CAP
    comptime BIG = ROOM + 88
    var payload = List[UInt8](length=BIG, fill=0)
    for i in range(BIG):
        payload[i] = UInt8(i & 0xFF)
    assert_equal(sender.send_to(Span(payload), to), BIG)
    _tick_until(driver, tracker, 1, "truncated delivery did not arrive")
    assert_equal(tracker.count, 1)
    assert_true((tracker.flags[0] & UInt32(IORING_CQE_F_MORE)) != 0, "still armed")
    assert_equal(tracker.results[0], BUF_SIZE, "result is the filled buffer")
    var bid = _buffer_id(tracker.flags[0])
    var buf = Span[UInt8, MutUntrackedOrigin](
        unsafe_ptr=mem.unsafe_offset(bid * BUF_SIZE), length=BUF_SIZE
    )
    var hdr = DeliveryHeader.parse(buf, name_capacity=NAME_CAP, control_capacity=0)
    assert_equal(Int(hdr.payloadlen()), BIG, "full datagram length")
    assert_true((Int(hdr.flags()) & MSG_TRUNC) != 0, "MSG_TRUNC set")
    var got = hdr.payload()
    assert_equal(len(got), ROOM, "payload clipped to the room")
    for i in range(ROOM):
        assert_equal(Int(got[i]), i & 0xFF)
    # The socket is drained and the op still armed: a normal datagram follows.
    driver.return_buffer(UInt16(GROUP), UInt16(bid))
    _send(sender, to, UInt8(1))
    _tick_until(driver, tracker, 2, "follow-up delivery did not arrive")
    assert_equal(tracker.results[1], DELIVERY_HEADER_LEN + NAME_CAP + 4)

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = cmp
    _ = tmpl


def test_sendmsg_on_same_fd_while_armed() raises:
    """A one-shot sendmsg on the multishot socket replies to the peer while the op stays armed."""
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var sender_port = Int(sender.local_addr_v4().port)

    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )
    _send(sender, to, UInt8(3))
    _tick_until(driver, tracker, 1, "delivery did not arrive")
    var tag = _check_delivery(mem, tracker.results[0], tracker.flags[0], sender_port)
    assert_equal(tag, 3)
    var bid = _buffer_id(tracker.flags[0])
    var slots_armed = driver._state[].pool.free_count()

    # Reply to the peer named in the delivery, through the same socket
    # the multishot op is armed on (each op holds its own dup in epoll).
    var reply = List[UInt8](length=3, fill=0)
    reply[0] = UInt8(ord("a"))
    reply[1] = UInt8(ord("c"))
    reply[2] = UInt8(ord("k"))
    var iov = iovec()
    iov.iov_base = UInt64(Int(reply.unsafe_ptr()))
    iov.iov_len = UInt64(3)
    var send_hdr = msghdr()
    send_hdr.msg_name = UInt64(Int(mem.unsafe_offset(bid * BUF_SIZE + DELIVERY_HEADER_LEN)))
    send_hdr.msg_namelen = UInt32(16)
    send_hdr.msg_iov = UInt64(Int(Pointer(to=iov)))
    send_hdr.msg_iovlen = UInt64(1)
    var send_tracker = Tracker()
    var send_cmp = _completion(send_tracker)
    driver.sendmsg(
        receiver.raw(), _ptr(send_hdr).unsafe_bitcast[NoneType](), _ptr(send_cmp)
    )
    assert_equal(driver._state[].pool.free_count(), slots_armed - 1)
    _tick_until(driver, send_tracker, 1, "sendmsg did not complete")
    assert_equal(send_tracker.count, 1)
    assert_equal(send_tracker.results[0], 3)
    assert_equal(tracker.count, 1, "no spurious multishot completion")
    assert_equal(driver._state[].pool.free_count(), slots_armed, "sendmsg slot freed")

    var inbox = List[UInt8](length=16, fill=0)
    var got = sender.recv_from_v4(Span(inbox))
    assert_equal(got[0], 3)
    assert_equal(Int(inbox[0]), ord("a"))
    assert_equal(Int(inbox[2]), ord("k"))
    assert_equal(Int(got[1].port), Int(to.port))

    # The multishot op is still armed after the sendmsg retired its dup.
    driver.return_buffer(UInt16(GROUP), UInt16(bid))
    _send(sender, to, UInt8(4))
    _tick_until(driver, tracker, 2, "post-reply delivery did not arrive")
    assert_equal(
        _check_delivery(mem, tracker.results[1], tracker.flags[1], sender_port), 4
    )

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = cmp
    _ = send_cmp
    _ = tmpl
    _ = send_hdr
    _ = iov
    _ = reply


def test_read_shutdown_ends_multishot() raises:
    """`shutdown(SHUT_RD)` on the socket ends the op with one terminal, then the driver blocks again.

    A read-shut UDP socket is reported readable forever while recvmsg
    keeps returning EAGAIN. The op must end on that wake instead of
    staying armed and turning every epoll_wait into a busy loop.
    """
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.connect(receiver.local_addr_v4())
    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    var slots_before = driver._state[].pool.free_count()

    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )
    receiver.shutdown(Shutdown.RD)
    _tick_until(driver, tracker, 1, "the read shutdown never ended the op")
    assert_equal(tracker.count, 1, "exactly one terminal")
    assert_equal(
        tracker.results[0], -Int(ECONNRESET), "a read-shut socket is ECONNRESET"
    )
    assert_equal(Int(tracker.flags[0]), 0, "no MORE on a terminal")
    assert_equal(driver._state[].pool.free_count(), slots_before, "slot freed")
    assert_equal(len(driver._state[].groups[0].free), BUF_COUNT, "no buffer taken")

    var start = perf_counter_ns()
    assert_equal(driver.tick(wait=True, timeout_ms=200), 0, "nothing left to fire")
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    assert_true(elapsed_ms >= 150, "the driver blocked for the whole timeout")
    assert_equal(tracker.count, 1, "the terminal fired once")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    _ = cmp
    _ = tmpl


def _closed_loopback_port() raises -> SocketAddrV4:
    """Return a loopback UDP address nothing listens on.

    A socket is bound to an ephemeral port and closed again; a datagram
    sent there draws an ICMP port-unreachable. Between the close and
    the send another process (the test runner is parallel) may bind
    that port, in which case no refusal comes back and the test that
    waits for it times out: a rare flake, not a library fault.
    """
    var probe = Socket.udp_v4()
    probe.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = probe.local_addr_v4()
    probe.close()
    return addr


def test_socket_error_ends_multishot_with_econnrefused() raises:
    """An ICMP port-unreachable on a connected UDP socket ends the op with -ECONNREFUSED.

    Without `IP_RECVERR` the error reaches the socket as its pending
    error alone: the socket reports EPOLLERR, the drain wakes, and the
    errno comes out of the first receive on it. The terminal carries
    -ECONNREFUSED with flags 0, the slot is freed and no buffer is kept.
    """
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.connect(_closed_loopback_port())
    var mem = _alloc_group(driver)
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    var slots_before = driver._state[].pool.free_count()

    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(GROUP),
        _ptr(cmp),
    )
    var ping = List[UInt8](length=4, fill=UInt8(1))
    assert_equal(receiver.send(Span(ping)), 4)
    _tick_until(driver, tracker, 1, "the socket error never ended the op")
    assert_equal(tracker.count, 1, "exactly one terminal")
    assert_equal(tracker.results[0], -Int(ECONNREFUSED))
    assert_equal(Int(tracker.flags[0]), 0, "no MORE on a terminal")
    assert_equal(driver._state[].pool.free_count(), slots_before, "slot freed")
    assert_equal(len(driver._state[].groups[0].free), BUF_COUNT, "no buffer taken")
    assert_equal(driver.tick(wait=False), 0, "nothing left to fire")

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    receiver.close()
    _ = cmp
    _ = tmpl


def main() raises:
    test_deliveries_then_enobufs()
    test_returned_buffers_are_reused()
    test_exact_fill_ends_with_enobufs()
    test_cancel_ends_multishot_with_ecanceled()
    test_cancel_after_close_releases_slot_and_dup()
    test_deliveries_per_tick_are_bounded()
    test_unregistered_group_ends_multishot_with_enobufs()
    test_control_messages_are_delivered()
    test_truncation_reports_full_length()
    test_sendmsg_on_same_fd_while_armed()
    test_read_shutdown_ends_multishot()
    test_socket_error_ends_multishot_with_econnrefused()
    print("PASS: test_epoll_multishot_recvmsg.mojo")
