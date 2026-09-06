"""Dropping a datagram stream while armed cancels the operation.

After the drop, stepping the loop releases the stream and pool slots and
no lease is outstanding; exactly one observable terminal completion is
reported, the cancel's own completion being internal. Also: dropping a
disarmed stream settles without a cancel, and handles are inert once
the loop is gone.
"""

from std.testing import assert_equal, assert_true

from boucle.drivers.backend import Backend
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.watch import WatchLoop


def _send(ref sender: Socket, ref to: SocketAddrV4, n: Int) raises:
    """Send a one-byte datagram carrying `n`."""
    var p = List[UInt8](length=1, fill=UInt8(n))
    assert_equal(sender.send_to(Span(p), to), 1)


def _run(backend: Backend) raises:
    """Drop while armed with two deliveries queued; both slots are released."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()

    var pool = loop.buffer_pool(4, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    _send(sender, to, 1)
    _send(sender, to, 2)
    var rounds = 0
    while stream.pending() < 2:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "deliveries did not arrive")
    assert_equal(pool.available(), 2, "two leases held by queued deliveries")
    assert_equal(loop._streams.active(), 1)
    assert_equal(loop._pools.active(), 1)

    _ = stream^  # drop while armed
    assert_equal(pool.available(), 4, "queued leases return at once")
    _ = pool^

    # The first call's pre-tick flush submits the cancel. The target's
    # -ECANCELED terminal and the cancel's own completion may land in one
    # tick or in two, in either order, so step until both slots are gone
    # and count what was reported: the terminal is observable, the
    # cancel's completion is not. A 100 ms bound instead of 0 lets the
    # completions land on a busy machine.
    var observed = 0
    rounds = 0
    while loop._streams.active() > 0 or loop._pools.active() > 0:
        observed += loop.step(100)
        rounds += 1
        assert_true(rounds < 50, "slots never released after the drop")
    assert_equal(
        observed, 1, "the terminal is observable, the cancel's completion is not"
    )
    assert_equal(loop._streams.active(), 0, "stream slot released")
    assert_equal(loop._pools.active(), 0, "pool slot released")
    assert_equal(loop.in_flight_count(), 0)
    assert_equal(loop._pending, 0, "neither the stream nor the cancel was pending")
    assert_equal(len(loop._deferred[]), 0)

    receiver.close()
    sender.close()
    _ = loop^


def test_drop_while_disarmed_settles_without_cancel(backend: Backend) raises:
    """Two buffers, three datagrams: ENOBUFS disarms; the drop settles at the next sweep."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()

    var pool = loop.buffer_pool(2, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    for n in range(3):
        _send(sender, to, n)
    var rounds = 0
    while not stream.error():
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "ENOBUFS never reported")
    assert_equal(stream.pending(), 2)
    assert_equal(pool.available(), 0)

    _ = stream^
    assert_equal(pool.available(), 2)
    _ = pool^
    var observed = loop.step(0)
    assert_equal(observed, 0, "no completion: nothing was in flight")
    assert_equal(loop._streams.active(), 0)
    _ = loop.step(0)
    assert_equal(loop._pools.active(), 0)
    assert_equal(loop.in_flight_count(), 0)
    assert_equal(loop._pending, 0)
    assert_equal(len(loop._deferred[]), 0)

    receiver.close()
    sender.close()
    _ = loop^


def test_handles_inert_after_loop_destruction() raises:
    """A stream and its pool outliving the loop read state and touch nothing."""
    var loop = WatchLoop(capacity=8, backend=Backend.EPOLL)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var pool = loop.buffer_pool(2, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    _ = loop^
    assert_true(stream.armed(), "state is still readable")
    assert_equal(stream.pending(), 0)
    assert_true(not stream.next(), "nothing queued")
    var raised = False
    try:
        stream.rearm()
    except e:
        raised = "loop destroyed" in String(e)
    assert_true(raised, "rearm() reports the destroyed loop")
    _ = stream^  # armed, but the loop is gone: no cancel is requested
    assert_equal(pool.capacity(), 2)
    assert_equal(pool.available(), pool.capacity(), "no lease is out")
    _ = pool^
    receiver.close()


def main() raises:
    _run(Backend.AUTO)
    test_drop_while_disarmed_settles_without_cancel(Backend.AUTO)
    print("ok: AUTO")
    _run(Backend.EPOLL)
    test_drop_while_disarmed_settles_without_cancel(Backend.EPOLL)
    print("ok: EPOLL")
    test_handles_inert_after_loop_destruction()
    print("ok: inert after loop destruction")
    print("PASS: test_stream_drop.mojo")
