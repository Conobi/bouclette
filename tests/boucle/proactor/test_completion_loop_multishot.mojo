"""`CompletionLoop` exposes buffer groups and multishot recvmsg on both
backends, and raw users decode flags with the portable buffer_id /
has_more helpers instead of io_uring constants.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true

from boucle.drivers.backend import Backend
from boucle.net.addr import SocketAddrV4
from boucle.net.message import DeliveryHeader
from boucle.net.socket import Socket
from boucle.proactor import CompletionLoop, Completion, buffer_id, has_more
from boucle.socle.linux.raw import msghdr

comptime BUF_COUNT = 4
comptime BUF_SIZE = 256
comptime NAME_CAP = 28


struct Tracker:
    """Records every completion fired on one Completion."""

    var count: Int
    var results: Array[Int, 8]
    var flags: Array[UInt32, 8]

    def __init__(out self):
        """Construct an empty tracker."""
        self.count = 0
        self.results = Array[Int, 8](fill=0)
        self.flags = Array[UInt32, 8](fill=UInt32(0))

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """Store result and flags at the next index."""
        var self_ptr = Pointer[Tracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        var i = self_ptr[].count
        if i < 8:
            self_ptr[].results[i] = result
            self_ptr[].flags[i] = flags
        self_ptr[].count += 1


def _ptr[T: AnyType](ref value: T) -> Pointer[T, MutUntrackedOrigin]:
    """Untracked pointer to a caller-owned value."""
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=value))
    )


def _run(backend: Backend) raises:
    """Two datagrams land in two distinct buffers; later ones reuse them.

    Both delivered ids are returned to the group, then three more
    datagrams are sent one at a time, each buffer returned before the
    next send so the group never runs dry (an empty io_uring ring ends
    the multishot with -ENOBUFS). The fifth delivery must land in one of
    the two ids returned first, which proves ids are recycled rather
    than consumed.

    Args:
        backend: The backend the loop is forced onto.
    """
    var loop = CompletionLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](BUF_COUNT * BUF_SIZE))
    )
    loop.register_buffer_group(mem, UInt32(BUF_SIZE), BUF_COUNT, UInt16(1))

    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var tracker = Tracker()
    var cmp = Completion(
        invoke=Tracker.on_complete,
        context=_ptr(tracker).unsafe_bitcast[NoneType](),
    )
    loop.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(1),
        _ptr(cmp),
    )
    loop.poll()

    for tag in range(2):
        var payload = List[UInt8](length=2, fill=UInt8(tag))
        assert_equal(sender.send_to(Span(payload), to), 2)
    # Bounded ticks: a missed delivery fails the test instead of hanging.
    var ticks = 0
    while tracker.count < 2:
        _ = loop.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 50, "deliveries did not arrive")

    for i in range(2):
        var bid = buffer_id(tracker.flags[i])
        assert_true(bid, "delivery carries a buffer id")
        assert_true(has_more(tracker.flags[i]), "multishot still armed")
        assert_equal(tracker.results[i], 16 + NAME_CAP + 2)
        var buf = Span[UInt8, MutUntrackedOrigin](
            unsafe_ptr=mem.unsafe_offset(Int(bid.value()) * BUF_SIZE),
            length=BUF_SIZE,
        )
        var hdr = DeliveryHeader.parse(
            buf, name_capacity=NAME_CAP, control_capacity=0
        )
        assert_equal(Int(hdr.payloadlen()), 2)
        loop.return_buffer(UInt16(1), bid.value())

    var first = buffer_id(tracker.flags[0]).value()
    var second = buffer_id(tracker.flags[1]).value()
    assert_true(first != second, "two in-flight deliveries use two buffers")

    # One datagram per round, returned before the next send. With four
    # buffers the fifth delivery must reuse a returned id on both
    # backends: the io_uring ring is FIFO (2, 3, then 0 again) and the
    # epoll free list is LIFO (the last returned id every time).
    for round in range(3):
        var payload = List[UInt8](length=2, fill=UInt8(2 + round))
        assert_equal(sender.send_to(Span(payload), to), 2)
        ticks = 0
        while tracker.count < 3 + round:
            _ = loop.tick(wait=True, timeout_ms=1000)
            ticks += 1
            assert_true(ticks < 50, "later delivery did not arrive")
        var bid = buffer_id(tracker.flags[2 + round])
        assert_true(bid, "later delivery carries a buffer id")
        assert_true(has_more(tracker.flags[2 + round]), "still armed")
        loop.return_buffer(UInt16(1), bid.value())

    var fifth = buffer_id(tracker.flags[4]).value()
    assert_true(
        fifth == first or fifth == second,
        "fifth delivery reuses a returned buffer",
    )

    loop.unregister_buffer_group(UInt16(1))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = tmpl
    _ = tracker
    _ = cmp


def main() raises:
    _run(Backend.AUTO)
    print("ok: AUTO")
    _run(Backend.EPOLL)
    print("ok: EPOLL")
    print("PASS: test_completion_loop_multishot.mojo")
