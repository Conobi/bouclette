"""Dropping a datagram stream while armed cancels the operation.

After the drop, stepping the loop releases the stream and pool slots and
no lease is outstanding; nothing is reported by step(), because neither
the terminal completion of a dropped stream nor the cancel's own
completion can be observed through a handle, and a datagram delivered
after the drop is recycled without leaking a lease. Also: dropping a
disarmed stream settles without a cancel, a pool dropped while its
stream is still settling keeps its slot until the stream is gone, and
handles are inert once the loop is gone, the pool's memory being
leaked when a stream was attached so a surviving datagram still reads
its bytes, whether the pool's own handle outlived the loop or not.
"""

from std.testing import assert_equal, assert_true

from boucle.drivers.backend import Backend
from boucle.net.addr import SocketAddrV4
from boucle.net.options import AddrFamily
from boucle.net.socket import Socket
from boucle.watch import WatchLoop


def _send(ref sender: Socket, ref to: SocketAddrV4, n: Int) raises:
    """Send a one-byte datagram carrying `n`."""
    var p = List[UInt8](length=1, fill=UInt8(n))
    assert_equal(sender.send_to(Span(p), to), 1)


def _run(backend: Backend) raises:
    """Drop while armed with two deliveries queued; both slots are released.

    A post-drop delivery is recycled driver-side too: a second stream
    over the same pool gets one delivery per buffer.
    """
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
    # Private slot counters: slot release is not visible through the public API.
    assert_equal(loop._streams.active(), 1)
    assert_equal(loop._pools.active(), 1)

    _ = stream^  # drop while armed
    assert_equal(pool.available(), 4, "queued leases return at once")
    # A datagram sent after the drop may still be delivered before the
    # cancel lands: the driver recycles its buffer and no lease leaks.
    _send(sender, to, 3)

    # The first call's pre-tick flush submits the cancel. The target's
    # -ECANCELED terminal and the cancel's own completion may land in one
    # tick or in two, in either order, so step until the stream slot is
    # gone and count what was reported: neither is observable once the
    # handle is gone. A 100 ms bound instead of 0 lets the completions
    # land on a busy machine.
    var observed = 0
    rounds = 0
    # Private slot counters: slot release is not visible through the public API.
    while loop._streams.active() > 0:
        observed += loop.step(100)
        rounds += 1
        assert_true(rounds < 50, "stream slot never released after the drop")
    assert_equal(
        observed, 0, "no completion of a dropped stream is reported"
    )
    assert_equal(pool.available(), 4, "a post-drop delivery is recycled")
    # A second stream on the same pool still gets one delivery per
    # buffer, so every buffer is back in the ring on both backends.
    var again = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    for n in range(4):
        _send(sender, to, 10 + n)
    rounds = 0
    while again.pending() < 4:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "the second stream did not get 4 deliveries")
    assert_equal(pool.available(), 0, "all four buffers leased again")
    _ = again^
    assert_equal(pool.available(), 4)
    rounds = 0
    # Private slot counters: slot release is not visible through the public API.
    while loop._streams.active() > 0:
        _ = loop.step(100)
        rounds += 1
        assert_true(rounds < 50, "second stream slot never released")
    _ = pool^
    _ = loop.step(0)
    # Private slot counters: slot release is not visible through the public API.
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
    # Private slot counters: slot release is not visible through the public API.
    assert_equal(loop._streams.active(), 0)
    _ = loop.step(0)
    # Private slot counters: slot release is not visible through the public API.
    assert_equal(loop._pools.active(), 0)
    assert_equal(loop.in_flight_count(), 0)
    assert_equal(loop._pending, 0)
    assert_equal(len(loop._deferred[]), 0)

    receiver.close()
    sender.close()
    _ = loop^


def test_pool_waits_for_the_stream(backend: Backend) raises:
    """A pool dropped while its stream is still settling keeps its slot."""
    var loop = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var pool = loop.buffer_pool(2, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    var pool_state = pool._state
    _ = stream^
    _ = pool^
    assert_true(not pool_state[]._queued, "the pool cannot settle yet")
    assert_equal(pool_state[].streams, 1)
    # Nothing settles before a sweep, so this holds on both backends:
    # the stream slot is still allocated, and with it the pool's.
    # Private slot counters: slot release is not visible through the public API.
    assert_equal(loop._streams.active(), 1, "stream still settling")
    assert_equal(loop._pools.active(), 1, "pool slot held while the stream is")
    assert_true(pool_state[].registered, "group still registered")
    var observed = 0
    var rounds = 0
    # Private slot counters: slot release is not visible through the public API.
    while loop._streams.active() > 0 or loop._pools.active() > 0:
        observed += loop.step(100)
        rounds += 1
        assert_true(rounds < 50, "slots never released after the drop")
    assert_equal(observed, 0)
    assert_equal(loop.in_flight_count(), 0)
    receiver.close()
    _ = loop^


def test_handles_inert_after_loop_destruction(backend: Backend) raises:
    """A stream and its pool outliving the loop read state and touch nothing.

    A datagram is in the socket when the loop dies, so the armed
    receive may still be writing into the pool: the pool's memory is
    leaked on purpose and stays readable afterwards.
    """
    var loop = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    var pool = loop.buffer_pool(2, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    _send(sender, to, 1)
    _ = loop^
    # Private state check: the flag the pool's free guard reads.
    assert_true(
        pool._state[]._abandoned, "a pool with a stream leaks its memory"
    )
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
    sender.close()


def test_datagram_survives_loop_destruction(backend: Backend) raises:
    """A delivery held across loop destruction keeps reading its bytes.

    One delivery is taken and a second left queued when the loop dies.
    The pool's memory is leaked, not freed, so every accessor of the
    held datagram still reads what the kernel wrote; the queued one is
    still handed out by `next()`; dropping both is inert.
    """
    var loop = WatchLoop(capacity=8, backend=backend)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    var pool = loop.buffer_pool(4, 256)
    var stream = loop.recv_msg_multishot(receiver, pool)
    _ = loop.step(0)
    _send(sender, to, 7)
    _send(sender, to, 9)
    var rounds = 0
    while stream.pending() < 2:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "deliveries did not arrive")
    var first = stream.next()
    var held = first.take()
    assert_equal(stream.pending(), 1)
    var available = pool.available()
    assert_equal(available, 2, "two leases out")

    _ = loop^
    # Private state check: the flag the pool's free guard reads.
    assert_true(pool._state[]._abandoned, "memory leaked, not freed")

    var payload = held.payload()
    assert_equal(len(payload), 1, "payload still readable")
    assert_equal(payload[0], UInt8(7))
    assert_true(not held.truncated())
    assert_true(not held.control_truncated())
    assert_true(held.peer_family() == AddrFamily.INET)
    assert_equal(held.peer_v4().port, sender.local_addr_v4().port)
    assert_true(not held.control().ecn(), "no control data was asked for")

    var second = stream.next()
    assert_true(Bool(second), "the queued delivery is still handed out")
    var later = second.take()
    var payload2 = later.payload()
    assert_equal(len(payload2), 1)
    assert_equal(payload2[0], UInt8(9))
    assert_equal(stream.pending(), 0)

    _ = held^
    _ = later^
    assert_equal(
        pool.available(), available, "leases cannot return to a gone loop"
    )
    _ = stream^
    _ = pool^
    receiver.close()
    sender.close()


def test_loop_gone_with_a_lease_out_leaks_a_readable_pool(backend: Backend) raises:
    """Loop gone with a lease out: the pool is leaked and stays readable.

    The stream and the pool handles are both dropped without a step in
    between, so the loop dies with the cancel never submitted: the
    stream is still armed and the pool still referenced when the
    destructor runs. What this pins is observable behaviour: the pool's
    memory is still there afterwards, the datagram held across the
    destruction reads its bytes, and dropping it is inert. The
    `_abandoned` free guard in the pool's `__deinit__` is not what
    keeps the memory alive here (nothing frees a pool the loop
    leaked), and whether that guard fires is unobservable without a
    sanitizer; the flag is checked below as a state check only.

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
    _ = loop.step(0)
    _send(sender, to, 5)
    var rounds = 0
    while stream.pending() < 1:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "the delivery did not arrive")
    var first = stream.next()
    var held = first.take()
    var pool_state = pool._state

    _ = stream^  # armed: the cancel waits for a step that never comes
    _ = pool^
    assert_equal(pool_state[].streams, 1, "the stream still references the pool")
    _ = loop^
    # Private state check: the flag the pool's free guard reads.
    assert_true(held.buffer._pool[]._abandoned, "the pool is marked abandoned")
    assert_true(
        Int(held.buffer._pool[].memory) != 0, "the memory pointer is kept"
    )

    var payload = held.payload()
    assert_equal(len(payload), 1, "payload still readable")
    assert_equal(payload[0], UInt8(5))
    assert_equal(held.count(), 1)
    assert_equal(held.peer_v4().port, sender.local_addr_v4().port)
    _ = held^  # inert: the lease cannot return to a gone loop
    receiver.close()
    sender.close()


def main() raises:
    _run(Backend.AUTO)
    test_drop_while_disarmed_settles_without_cancel(Backend.AUTO)
    test_pool_waits_for_the_stream(Backend.AUTO)
    test_handles_inert_after_loop_destruction(Backend.AUTO)
    test_datagram_survives_loop_destruction(Backend.AUTO)
    test_loop_gone_with_a_lease_out_leaks_a_readable_pool(Backend.AUTO)
    print("ok: AUTO")
    _run(Backend.EPOLL)
    test_drop_while_disarmed_settles_without_cancel(Backend.EPOLL)
    test_pool_waits_for_the_stream(Backend.EPOLL)
    test_handles_inert_after_loop_destruction(Backend.EPOLL)
    test_datagram_survives_loop_destruction(Backend.EPOLL)
    test_loop_gone_with_a_lease_out_leaks_a_readable_pool(Backend.EPOLL)
    print("ok: EPOLL")
    print("PASS: test_stream_drop.mojo")
