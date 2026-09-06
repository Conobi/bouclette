"""A multishot recvmsg stream over UDP loopback, on both backends.

64 datagrams sent in four batches across several step() calls are all
drained with the right payloads and peers; a reply is sent from the
receiving socket with send_msg while the stream is armed; afterwards the
pool is full again and the stream is still armed. Every precondition of
recv_msg_multishot raises EINVAL without arming anything, a stream
socket is refused the same way, an oversized datagram is cut and flagged
with its full length kept, and an ECN mark travels through the stream's
control area.
"""

from std.testing import assert_equal, assert_true

from boucle.drivers.backend import Backend
from boucle.error import IOError
from boucle.net.addr import SocketAddrV4
from boucle.net.message import DELIVERY_HEADER_LEN, Message
from boucle.net.options import AddrFamily
from boucle.net.socket import Socket
from boucle.net.options import Backlog
from boucle.socle.platform import EAGAIN, EINVAL
from boucle.watch import WatchLoop
from boucle.watch.pool import BufferPool
from boucle.watch.stream import Datagram

comptime BATCHES = 4
comptime PER_BATCH = 16


def _payload(n: Int) -> List[UInt8]:
    """Build the 4-byte datagram 'D', n, 0x55, '!'."""
    var p = List[UInt8](length=4, fill=0)
    p[0] = UInt8(ord("D"))
    p[1] = UInt8(n)
    p[2] = UInt8(0x55)
    p[3] = UInt8(ord("!"))
    return p^


def _drain_reply(ref sender: Socket, mut loop: WatchLoop) raises -> Int:
    """Read one reply from `sender`, stepping the loop while it is not there yet.

    Returns:
        The datagram number echoed in the reply.
    """
    var buf = List[UInt8](length=8, fill=0)
    for _ in range(200):
        var count = -1
        try:
            count = sender.recv_from_v4(Span(buf))[0]
        except e:
            if e != IOError(positive_errno=EAGAIN):
                raise e
        if count >= 0:
            assert_equal(count, 2, "reply is two bytes")
            assert_equal(Int(buf[0]), ord("R"))
            return Int(buf[1])
        _ = loop.step(10)
    raise "reply never arrived"


def _run(backend: Backend) raises:
    """Send 64 datagrams in batches, drain them through the stream, reply to each."""
    var loop = WatchLoop(capacity=16, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var sender_addr = sender.local_addr_v4()

    var pool = loop.buffer_pool(64, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    assert_true(stream.armed())
    assert_equal(loop.in_flight_count(), 2, "one pool, one stream")
    _ = loop.step(0)  # hand the multishot to the kernel

    var seen = List[Bool](length=BATCHES * PER_BATCH, fill=False)
    for batch in range(BATCHES):
        for i in range(PER_BATCH):
            var n = batch * PER_BATCH + i
            assert_equal(sender.send_to(Span(_payload(n)), to), 4)

        var got = 0
        var rounds = 0
        var observed = 0
        while got < PER_BATCH:
            observed += loop.step(1000)
            rounds += 1
            assert_true(rounds < 200, "batch did not arrive")
            while True:
                var d = stream.next()
                if not d:
                    break
                var dg = d.take()
                var p = dg.payload()
                assert_equal(len(p), 4)
                assert_equal(Int(p[0]), ord("D"))
                var n = Int(p[1])
                assert_true(n < BATCHES * PER_BATCH, "datagram number in range")
                assert_true(not seen[n], "each datagram delivered once")
                seen[n] = True
                assert_equal(dg.peer_family().id, AddrFamily.INET.id)
                var peer = dg.peer_v4()
                assert_equal(peer.port, sender_addr.port)
                assert_true(not dg.truncated())

                # Reply from the receiving socket while the stream is armed.
                var reply = List[UInt8](length=2, fill=0)
                reply[0] = UInt8(ord("R"))
                reply[1] = UInt8(n)
                var msg = Message(reply^)
                msg.set_peer(sender_addr)
                var f = loop.send_msg(receiver, msg^)
                loop.run()  # drains the one-shot; the stream stays armed
                assert_equal(f^.result().count, 2)
                assert_equal(_drain_reply(sender, loop), n)
                got += 1
                _ = dg^  # lease returns
        assert_equal(stream.pending(), 0)
        # The counted step() calls report stream deliveries only: the first
        # one always sees at least one datagram, and deliveries dispatched by
        # run() or by the reply drain are not counted, so the sum never
        # exceeds the batch.
        assert_true(observed >= 1, "the first step of a batch reports a delivery")
        assert_true(observed <= PER_BATCH, "step() reports each delivery once")

    for n in range(BATCHES * PER_BATCH):
        assert_true(seen[n], String("datagram ", n, " missing"))
    assert_equal(pool.available(), pool.capacity())
    assert_true(stream.armed(), "stream still armed after draining")
    assert_true(not stream.error(), "no error")

    _ = stream^
    _ = pool^
    # Dropping an armed stream submits a cancel at the next flush; once the
    # terminal and the cancel's own completion have both landed the stream
    # slot is released, which detaches the pool and releases its slot too.
    var rounds = 0
    while loop._streams.active() > 0 or loop._pools.active() > 0:
        _ = loop.step(100)
        rounds += 1
        assert_true(rounds < 50, "slots never released after the drop")
    assert_equal(loop.in_flight_count(), 0)
    receiver.close()
    sender.close()
    _ = loop^


def _expect_einval(
    mut loop: WatchLoop,
    ref socket: Socket,
    ref pool: BufferPool,
    control_capacity: Int,
    what: String,
) raises:
    """Assert that arming a stream with these arguments raises EINVAL.

    Args:
        loop: The loop to arm on.
        socket: The datagram socket.
        pool: The pool to deliver into.
        control_capacity: The control capacity to request.
        what: Describes the rejection for the assertion message.
    """
    var raised = False
    try:
        _ = loop.recv_msg_multishot(
            socket, pool, control_capacity=control_capacity
        )
    except e:
        raised = "EINVAL" in String(e)
    assert_true(raised, what)


def test_multishot_rejections(backend: Backend) raises:
    """Every precondition of recv_msg_multishot raises EINVAL and arms nothing.

    The closing-pool case cannot be reached through the public API (a
    pool closes when its handle drops, and the handle is what the call
    takes), so it is forced through the state; the check stays as a
    defensive one.

    Args:
        backend: The loop backend to force.
    """
    var loop = WatchLoop(capacity=8, backend=backend)
    var other = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var small = loop.buffer_pool(2, 64)
    var pool = loop.buffer_pool(2, 256)
    var foreign = other.buffer_pool(2, 256)
    var before = loop.in_flight_count()

    _expect_einval(
        loop, receiver, small, 64, "pool too small for the control area"
    )
    _expect_einval(loop, receiver, foreign, 0, "pool from another loop")
    _expect_einval(loop, receiver, pool, -1, "negative control capacity")
    # `closing` is set by the handle's destructor, after which no caller
    # can name the pool: the check is defensive and forced here by hand.
    pool._state[].closing = True
    _expect_einval(loop, receiver, pool, 0, "closing pool")
    pool._state[].closing = False

    assert_equal(loop.in_flight_count(), before, "nothing was armed")
    assert_equal(loop._streams.active(), 0)
    assert_equal(pool._state[].streams, 0, "no stream counts against the pool")
    _ = pool^
    _ = small^
    _ = foreign^
    _ = loop.step(0)
    _ = other.step(0)
    assert_equal(loop.in_flight_count(), 0)
    assert_equal(other.in_flight_count(), 0)
    receiver.close()
    _ = loop^
    _ = other^


def test_stream_truncation(backend: Backend) raises:
    """A datagram larger than the payload region is cut and flagged, with its full length kept.

    Args:
        backend: The loop backend to force.
    """
    comptime ROOM = 100
    var loop = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    var pool = loop.buffer_pool(2, DELIVERY_HEADER_LEN + 28 + ROOM)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)

    var big = List[UInt8](length=300, fill=0)
    for i in range(300):
        big[i] = UInt8(i & 0xFF)
    assert_equal(sender.send_to(Span(big), to), 300)
    var rounds = 0
    while stream.pending() == 0:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "the datagram did not arrive")
    var first = stream.next()
    var dg = first.take()
    assert_true(dg.truncated(), "MSG_TRUNC is reported")
    assert_true(not dg.control_truncated())
    var payload = dg.payload()
    assert_equal(len(payload), ROOM, "the payload is cut at the region")
    for i in range(ROOM):
        assert_equal(payload[i], UInt8(i & 0xFF))
    assert_equal(Int(dg._header().payloadlen()), 300, "full length kept")
    assert_true(stream.armed(), "a truncated delivery does not end the stream")
    _ = dg^
    _ = stream^
    _ = pool^
    rounds = 0
    while loop._streams.active() > 0 or loop._pools.active() > 0:
        _ = loop.step(100)
        rounds += 1
        assert_true(rounds < 50, "slots never released after the drop")
    receiver.close()
    sender.close()
    _ = loop^


def test_multishot_refuses_stream_socket(backend: Backend) raises:
    """A multishot receive on a TCP socket raises EINVAL and arms nothing.

    The multishot asks the kernel for MSG_TRUNC, which on a stream
    socket discards the bytes it reports; a stream socket is refused
    before any driver resource (an epoll dup, an op slot) is taken.

    Args:
        backend: The loop backend to force.
    """
    var loop = WatchLoop(capacity=8, backend=backend)
    var listener = Socket.tcp_v4()
    listener.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    listener.listen(Backlog(4))
    var pool = loop.buffer_pool(2, 256)
    var before = loop.in_flight_count()
    var slots_before = -1
    if loop.backend() == Backend.EPOLL:
        slots_before = loop._driver._epoll.value()._state[].pool.free_count()

    var raised = False
    try:
        _ = loop.recv_msg_multishot(listener, pool)
    except e:
        raised = e == IOError(positive_errno=EINVAL)
    assert_true(raised, "a stream socket is refused with EINVAL")
    assert_equal(loop.in_flight_count(), before, "nothing was armed")
    assert_equal(loop._streams.active(), 0)
    assert_equal(pool._state[].streams, 0)
    if loop.backend() == Backend.EPOLL:
        assert_equal(
            loop._driver._epoll.value()._state[].pool.free_count(),
            slots_before,
            "no epoll op slot (and so no dup) was taken",
        )
    _ = pool^
    _ = loop.step(0)
    assert_equal(loop.in_flight_count(), 0)
    listener.close()
    _ = loop^


def test_stream_ecn_roundtrip(backend: Backend) raises:
    """An ECN mark set on the sender arrives through the stream's control area.

    Args:
        backend: The loop backend to force.
    """
    var loop = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.set_recv_tos()
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var sender_addr = sender.local_addr_v4()

    var pool = loop.buffer_pool(4, 256)
    var stream = loop.recv_msg_multishot(receiver, pool, control_capacity=64)
    _ = loop.step(0)

    var out = Message(List[UInt8](length=3, fill=1), control_capacity=24)
    out.set_peer(to)
    out.set_ecn(2)
    var f = loop.send_msg(sender, out^)
    loop.run()
    assert_equal(f^.result().count, 3)

    var rounds = 0
    while stream.pending() == 0:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "the marked datagram never arrived")
    var d = stream.next()
    var dg = d.take()
    assert_equal(len(dg.payload()), 3)
    assert_true(not dg.control_truncated(), "64 bytes hold the record")
    var mark = dg.control().ecn()
    assert_true(Bool(mark), "an IP_TOS record arrived")
    assert_equal(Int(mark.value()), 2)
    assert_equal(dg.peer_v4().port, sender_addr.port)
    _ = dg^
    assert_equal(pool.available(), 4)

    _ = stream^
    _ = pool^
    rounds = 0
    while loop._streams.active() > 0 or loop._pools.active() > 0:
        _ = loop.step(100)
        rounds += 1
        assert_true(rounds < 50, "slots never released after the drop")
    receiver.close()
    sender.close()
    _ = loop^


def main() raises:
    _run(Backend.AUTO)
    test_multishot_rejections(Backend.AUTO)
    test_multishot_refuses_stream_socket(Backend.AUTO)
    test_stream_truncation(Backend.AUTO)
    test_stream_ecn_roundtrip(Backend.AUTO)
    print("ok: AUTO")
    _run(Backend.EPOLL)
    test_multishot_rejections(Backend.EPOLL)
    test_multishot_refuses_stream_socket(Backend.EPOLL)
    test_stream_truncation(Backend.EPOLL)
    test_stream_ecn_roundtrip(Backend.EPOLL)
    print("ok: EPOLL")
    print("PASS: test_datagram_stream.mojo")
