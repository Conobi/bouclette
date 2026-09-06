"""A multishot recvmsg stream over UDP loopback, on both backends.

64 datagrams sent in four batches across several step() calls are all
drained with the right payloads and peers; a reply is sent from the
receiving socket with send_msg while the stream is armed; afterwards the
pool is full again and the stream is still armed.
"""

from std.testing import assert_equal, assert_true

from boucle.drivers.backend import Backend
from boucle.error import IOError
from boucle.net.addr import SocketAddrV4
from boucle.net.message import Message
from boucle.net.options import AddrFamily
from boucle.net.socket import Socket
from boucle.socle.platform import EAGAIN
from boucle.watch import WatchLoop
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


def main() raises:
    _run(Backend.AUTO)
    print("ok: AUTO")
    _run(Backend.EPOLL)
    print("ok: EPOLL")
    print("PASS: test_datagram_stream.mojo")
