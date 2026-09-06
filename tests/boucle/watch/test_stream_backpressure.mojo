"""Holding leases is the backpressure lever of a datagram stream.

Four buffers, eight datagrams: four deliveries are held, the stream ends
with ENOBUFS, error() reports it and armed() is False. Dropping the held
datagrams returns the leases; rearm() resubmits; the remaining four
datagrams arrive. rearm() on an armed stream is a misuse and raises.
"""

from std.testing import assert_equal, assert_true

from boucle.drivers.backend import Backend
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.socle.platform import ENOBUFS
from boucle.watch import WatchLoop
from boucle.watch.stream import Datagram


def _run(backend: Backend) raises:
    """Exhaust the pool, observe ENOBUFS, return leases, re-arm, drain the rest."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()

    var pool = loop.buffer_pool(4, 256)
    assert_equal(pool.capacity(), 4)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)

    for n in range(8):
        var p = List[UInt8](length=1, fill=UInt8(n))
        assert_equal(sender.send_to(Span(p), to), 1)

    var held = List[Datagram]()
    var rounds = 0
    while not stream.error():
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "ENOBUFS never reported")
        while True:
            var d = stream.next()
            if not d:
                break
            held.append(d.take())
    assert_equal(len(held), 4, "one delivery per buffer before the pool ran dry")
    assert_equal(pool.available(), 0)
    assert_true(not stream.armed())
    assert_equal(stream.error().value().errno_value(), ENOBUFS)
    assert_equal(
        loop.in_flight_count(),
        1,
        "a disarmed stream is not in flight; the pool is",
    )

    var seen = List[Bool](length=8, fill=False)
    for i in range(len(held)):
        var n = Int(held[i].payload()[0])
        assert_true(not seen[n])
        seen[n] = True
    held.clear()  # every lease returns
    assert_equal(pool.available(), 4)

    stream.rearm()
    assert_true(stream.armed())
    assert_true(not stream.error())
    assert_equal(loop.in_flight_count(), 2, "the re-armed stream counts again")
    var got = 0
    rounds = 0
    while got < 4:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "remaining datagrams did not arrive")
        while True:
            var d = stream.next()
            if not d:
                break
            var dg = d.take()
            var n = Int(dg.payload()[0])
            assert_true(not seen[n], "each datagram delivered once")
            seen[n] = True
            got += 1
            _ = dg^
    for n in range(8):
        assert_true(seen[n], String("datagram ", n, " missing"))
    assert_equal(pool.available(), 4)

    # A burst that exactly fills the pool ends the stream with ENOBUFS on
    # both backends even though no further datagram is queued: the kernel
    # and the epoll emulation both look for the next buffer before waiting
    # for the next datagram. The io_uring half relies on UDP recvmsg
    # leaving `msg_inq` unknown, which makes the kernel retry at once and
    # hit ENOBUFS; if a future kernel reports `msg_inq` for UDP, the stream
    # would stay armed and this assertion would need revisiting. Re-arm
    # and submit so the misuse check below runs on an armed stream.
    assert_true(not stream.armed(), "an exactly-filled pool ends the stream")
    assert_equal(stream.error().value().errno_value(), ENOBUFS)
    stream.rearm()
    _ = loop.step(0)
    assert_true(stream.armed())

    # rearm() while armed is a misuse and raises.
    var rearm_early_raised = False
    try:
        stream.rearm()
    except e:
        rearm_early_raised = "error()" in String(e)
    assert_true(rearm_early_raised, "rearm() is legal only after error()")
    assert_true(stream.armed(), "a rejected rearm() leaves the stream armed")

    _ = stream^
    _ = pool^
    # Dropping an armed stream submits a cancel at the next flush; once the
    # terminal and the cancel's own completion have both landed the stream
    # slot is released, which detaches the pool and releases its slot too.
    rounds = 0
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
    print("PASS: test_stream_backpressure.mojo")
