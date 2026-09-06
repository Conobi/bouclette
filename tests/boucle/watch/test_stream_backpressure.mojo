"""Holding leases is the backpressure lever of a datagram stream.

Four buffers, eight datagrams: four deliveries are held, the stream ends
with ENOBUFS, error() reports it and armed() is False. Dropping the held
datagrams returns the leases; rearm() resubmits; the remaining four
datagrams arrive. rearm() on an armed stream is a misuse and raises. A
re-arm the driver refuses with a genuine error disarms the stream with
that error. `run()` with nothing pending still submits a queued re-arm
before it returns. On epoll a read-shut socket ends the stream instead
of waking the loop forever; on io_uring it never ends the stream, which
stays armed until it is dropped.
"""

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.drivers.backend import Backend
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Shutdown
from boucle.net.socket import Socket
from boucle.socle.platform import EBADF, ECONNRESET, ENOBUFS, close_unchecked
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
    assert_equal(loop._pending, 0, "a stream's end was never pending")

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


def test_rearm_refused_by_a_driver_error_disarms() raises:
    """A re-arm the driver refuses with a real errno ends the stream with that error.

    On the epoll backend every re-arm registers a fresh private dup of
    the socket, so a descriptor closed underneath the `Socket` makes the
    driver refuse the re-arm with EBADF: the stream is disarmed with
    that error, nothing stays on the deferred list, and dropping it
    settles without a cancel.
    """
    var loop = WatchLoop(capacity=8, backend=Backend.EPOLL)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()

    var pool = loop.buffer_pool(2, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    for n in range(3):
        var p = List[UInt8](length=1, fill=UInt8(n))
        assert_equal(sender.send_to(Span(p), to), 1)
    var rounds = 0
    while not stream.error():
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "ENOBUFS never reported")
    while True:
        var d = stream.next()
        if not d:
            break
        _ = d.take()
    assert_equal(pool.available(), 2)

    close_unchecked(unsafe_fd=receiver.raw())
    stream.rearm()
    assert_true(stream.armed())
    assert_equal(loop.pending_composites(), 1, "the re-arm is deferred")
    _ = loop.step(0)
    receiver._handle._raw = -1  # the descriptor is already gone
    assert_true(not stream.armed(), "a refused re-arm disarms the stream")
    assert_true(Bool(stream.error()), "error() reports the refusal")
    assert_equal(stream.error().value().errno_value(), EBADF)
    assert_equal(loop.pending_composites(), 0, "nothing left to retry")
    assert_equal(loop.in_flight_count(), 1, "only the pool is in flight")

    _ = stream^
    _ = pool^
    _ = loop.step(0)
    _ = loop.step(0)
    assert_equal(loop._streams.active(), 0)
    assert_equal(loop._pools.active(), 0)
    sender.close()
    _ = loop^


def test_run_flushes_a_deferred_rearm(backend: Backend) raises:
    """`run()` with nothing pending submits a queued re-arm before returning.

    Args:
        backend: The loop backend to force.
    """
    var loop = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()

    var pool = loop.buffer_pool(2, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    var start = perf_counter_ns()
    loop.run()
    assert_true(
        (perf_counter_ns() - start) // 1_000_000 < 100,
        "run() with only a stream armed returns at once",
    )
    assert_true(stream.armed())
    assert_equal(loop.pending_composites(), 0, "the first arm was flushed")

    for n in range(3):
        var p = List[UInt8](length=1, fill=UInt8(n))
        assert_equal(sender.send_to(Span(p), to), 1)
    var rounds = 0
    while not stream.error():
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "ENOBUFS never reported")
    while True:
        var d = stream.next()
        if not d:
            break
        _ = d.take()
    assert_equal(pool.available(), 2)

    stream.rearm()
    assert_equal(loop.pending_composites(), 1, "the re-arm is deferred")
    start = perf_counter_ns()
    loop.run()
    assert_true(
        (perf_counter_ns() - start) // 1_000_000 < 100,
        "run() with only a re-arm queued returns at once",
    )
    assert_equal(loop.pending_composites(), 0, "run() flushed the re-arm")
    assert_true(stream.armed())
    assert_equal(loop._pending, 0)

    # The third datagram of the burst is still queued in the socket and
    # lands first; the one sent now follows it without a second run().
    var p = List[UInt8](length=1, fill=UInt8(9))
    assert_equal(sender.send_to(Span(p), to), 1)
    var seen_new = False
    rounds = 0
    while not seen_new:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "the datagram never arrived after run()")
        while True:
            var d = stream.next()
            if not d:
                break
            var dg = d.take()
            var n = Int(dg.payload()[0])
            assert_true(n == 2 or n == 9, "only the leftover and the new one")
            if n == 9:
                seen_new = True
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


def test_read_shutdown_ends_the_stream() raises:
    """On epoll, `shutdown(SHUT_RD)` ends an armed stream and the loop blocks again.

    The read-shut socket is reported readable at every wait while its
    recvmsg only ever returns EAGAIN: the stream must end with an error
    on that wake, and a further `step(200)` must sleep the whole bound.
    """
    var loop = WatchLoop(capacity=8, backend=Backend.EPOLL)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.connect(receiver.local_addr_v4())
    var pool = loop.buffer_pool(4, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    receiver.shutdown(Shutdown.RD)

    var rounds = 0
    while not stream.error():
        _ = loop.step(200)
        rounds += 1
        assert_true(rounds < 10, "the read shutdown never ended the stream")
    assert_true(not stream.armed())
    assert_equal(
        stream.error().value().errno_value(),
        ECONNRESET,
        "a read-shut socket reports ECONNRESET",
    )
    assert_equal(stream.pending(), 0)
    assert_equal(pool.available(), 4, "no buffer was leased")

    var start = perf_counter_ns()
    assert_equal(loop.step(200), 0, "nothing left to report")
    assert_true(
        (perf_counter_ns() - start) // 1_000_000 >= 150,
        "the loop slept the whole bound",
    )
    _ = stream^
    _ = pool^
    _ = loop.step(0)
    assert_equal(loop.in_flight_count(), 0)
    receiver.close()
    _ = loop^


def test_read_shutdown_keeps_io_uring_stream_armed() raises:
    """On io_uring, `shutdown(SHUT_RD)` never ends an armed stream.

    The kernel fires no completion for a read-shut socket: three bounded
    steps report nothing, the stream stays armed with no error, and only
    dropping it releases the slot. Skipped when the auto-detected
    backend is epoll, whose behaviour is pinned above.
    """
    var loop = WatchLoop(capacity=8, backend=Backend.AUTO)
    if loop.backend() != Backend.IO_URING:
        print("skip: io_uring unavailable")
        _ = loop^
        return
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.connect(receiver.local_addr_v4())
    var pool = loop.buffer_pool(4, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    receiver.shutdown(Shutdown.RD)

    for _ in range(3):
        assert_equal(loop.step(200), 0, "no completion for a read-shut socket")
        assert_true(stream.armed(), "the stream stays armed")
        assert_true(not stream.error(), "no error is reported")
    assert_equal(stream.pending(), 0)
    assert_equal(pool.available(), 4, "no buffer was leased")

    _ = stream^
    _ = pool^
    var rounds = 0
    while loop._streams.active() > 0 or loop._pools.active() > 0:
        _ = loop.step(100)
        rounds += 1
        assert_true(rounds < 50, "dropping the stream never released the slot")
    assert_equal(loop.in_flight_count(), 0)
    receiver.close()
    _ = loop^


def main() raises:
    _run(Backend.AUTO)
    test_run_flushes_a_deferred_rearm(Backend.AUTO)
    print("ok: AUTO")
    _run(Backend.EPOLL)
    test_run_flushes_a_deferred_rearm(Backend.EPOLL)
    print("ok: EPOLL")
    test_rearm_refused_by_a_driver_error_disarms()
    print("ok: refused re-arm")
    test_read_shutdown_ends_the_stream()
    print("ok: read shutdown")
    test_read_shutdown_keeps_io_uring_stream_armed()
    print("ok: io_uring read shutdown")
    print("PASS: test_stream_backpressure.mojo")
