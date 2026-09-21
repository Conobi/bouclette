"""`DatagramSink` tests: push, flush, lifecycle, error paths, both backends.

Exercises `push()`, `push_msg()`, `flush()`, slot exhaustion (ENOSPC),
oversized payloads (EMSGSIZE), batch submission, drop-with-in-flight
settlement, slot reuse after completion, epoll backend, and epoll's
`sendmmsg(2)` batch flush path.
"""

from std.testing import assert_equal, assert_true

from bouclette.drivers.backend import Backend
from bouclette.error import IOError
from bouclette.net.addr import SocketAddrV4
from bouclette.net.message import Message
from bouclette.net.socket import Socket
from bouclette.socle.platform import EMSGSIZE, ENOSPC
from bouclette.watch import DatagramSink, WatchLoop


def _payload(n: Int) -> List[UInt8]:
    """Build a 4-byte datagram: 'S', n, 0xAA, '!'."""
    var p = List[UInt8](length=4, fill=0)
    p[0] = UInt8(ord("S"))
    p[1] = UInt8(n)
    p[2] = UInt8(0xAA)
    p[3] = UInt8(ord("!"))
    return p^


def _recv_one(ref receiver: Socket) raises -> List[UInt8]:
    """Receive one datagram from a non-blocking socket.

    Returns:
        The received bytes as a list.
    """
    var buf = List[UInt8](length=64, fill=0)
    var n = receiver.recv_from_v4(Span(buf))[0]
    var result = List[UInt8](capacity=n)
    for i in range(n):
        result.append(buf[i])
    return result^


def test_push_flush_completes(backend: Backend) raises:
    """Push one datagram via `push()`, flush, step, verify completion and payload.

    Args:
        backend: The loop backend to force.
    """
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var sink = loop.datagram_sink(sender, capacity=4, max_payload=64)
    var data = _payload(1)
    sink.push(Span(data), addr)
    assert_equal(sink.pending(), 1, "one datagram queued")
    var submitted = sink.flush()
    assert_equal(submitted, 1, "one submitted")
    assert_equal(sink.in_flight(), 1, "one in flight")

    var rounds = 0
    while sink.completed() == 0:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "completion never arrived")
    assert_equal(sink.completed(), 1, "one completed")
    assert_equal(sink.failed(), 0, "none failed")

    # Verify payload on receiver side.
    var got = _recv_one(receiver)
    assert_equal(len(got), 4)
    assert_equal(Int(got[0]), ord("S"))
    assert_equal(Int(got[1]), 1)
    assert_equal(Int(got[2]), 0xAA)
    assert_equal(Int(got[3]), ord("!"))

    _ = sink^
    _ = loop.step(0)
    receiver.close()
    sender.close()
    _ = loop^


def test_push_msg_flush_completes(backend: Backend) raises:
    """Push a pre-built `Message` via `push_msg()`, flush, step, verify completion.

    Args:
        backend: The loop backend to force.
    """
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var sink = loop.datagram_sink(sender, capacity=4, max_payload=64)
    var msg = Message(_payload(2))
    msg.set_peer(addr)
    sink.push_msg(msg^)
    assert_equal(sink.pending(), 1)
    var submitted = sink.flush()
    assert_equal(submitted, 1)

    var rounds = 0
    while sink.completed() == 0:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "completion never arrived")
    assert_equal(sink.completed(), 1)
    assert_equal(sink.failed(), 0)

    # Verify payload on receiver side.
    var got = _recv_one(receiver)
    assert_equal(len(got), 4)
    assert_equal(Int(got[0]), ord("S"))
    assert_equal(Int(got[1]), 2)

    _ = sink^
    _ = loop.step(0)
    receiver.close()
    sender.close()
    _ = loop^


def test_slot_exhaustion_raises(backend: Backend) raises:
    """Create a sink with `capacity=2`; pushing a 3rd datagram raises ENOSPC.

    Args:
        backend: The loop backend to force.
    """
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var sink = loop.datagram_sink(sender, capacity=2, max_payload=64)
    var d1 = _payload(1)
    var d2 = _payload(2)
    sink.push(Span(d1), addr)
    sink.push(Span(d2), addr)
    assert_equal(sink.pending(), 2)

    var raised = False
    try:
        var d3 = _payload(3)
        sink.push(Span(d3), addr)
    except e:
        raised = e == IOError(positive_errno=ENOSPC)
    assert_true(raised, "3rd push raises ENOSPC")

    _ = sink^
    receiver.close()
    sender.close()
    _ = loop^


def test_emsgsize_on_oversized_payload(backend: Backend) raises:
    """Push a payload exceeding `max_payload`; raises EMSGSIZE.

    Args:
        backend: The loop backend to force.
    """
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var sink = loop.datagram_sink(sender, capacity=4, max_payload=8)
    var big = List[UInt8](length=16, fill=UInt8(0x42))

    var raised = False
    try:
        sink.push(Span(big), addr)
    except e:
        raised = e == IOError(positive_errno=EMSGSIZE)
    assert_true(raised, "oversized payload raises EMSGSIZE")

    _ = sink^
    receiver.close()
    sender.close()
    _ = loop^


def test_multiple_push_flush_batch(backend: Backend) raises:
    """Push 5 datagrams, flush once, step, verify all 5 complete.

    Args:
        backend: The loop backend to force.
    """
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=16, backend=backend)
    var sink = loop.datagram_sink(sender, capacity=8, max_payload=64)
    for i in range(5):
        var d = _payload(i)
        sink.push(Span(d), addr)
    assert_equal(sink.pending(), 5)
    var submitted = sink.flush()
    assert_equal(submitted, 5)

    var rounds = 0
    while sink.completed() < 5:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "not all completions arrived")
    assert_equal(sink.completed(), 5)
    assert_equal(sink.failed(), 0)

    # Drain the receiver to verify.
    for _ in range(5):
        var got = _recv_one(receiver)
        assert_equal(len(got), 4)
        assert_equal(Int(got[0]), ord("S"))

    _ = sink^
    _ = loop.step(0)
    receiver.close()
    sender.close()
    _ = loop^


def test_sink_drop_with_in_flight(backend: Backend) raises:
    """Push and flush 1 datagram, drop the sink while in flight, verify settlement.

    Args:
        backend: The loop backend to force.
    """
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var sink = loop.datagram_sink(sender, capacity=4, max_payload=64)
    var d = _payload(10)
    sink.push(Span(d), addr)
    _ = sink.flush()
    assert_true(sink.in_flight() > 0, "at least one in flight")
    _ = sink^  # drop while in flight

    # Step until the slab settles.
    var rounds = 0
    while loop._sinks.active() > 0:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "sink slot never settled")
    assert_equal(loop.in_flight_count(), 0, "all cleaned up")

    # Drain the receiver so nothing lingers.
    _ = _recv_one(receiver)
    receiver.close()
    sender.close()
    _ = loop^


def test_slot_reuse_after_completion(backend: Backend) raises:
    """Create a sink with `capacity=2`, fill it, complete, refill, verify reuse.

    Args:
        backend: The loop backend to force.
    """
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var sink = loop.datagram_sink(sender, capacity=2, max_payload=64)

    # First batch: fill both slots.
    var d1 = _payload(1)
    var d2 = _payload(2)
    sink.push(Span(d1), addr)
    sink.push(Span(d2), addr)
    _ = sink.flush()
    var rounds = 0
    while sink.completed() < 2:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "first batch did not complete")
    assert_equal(sink.completed(), 2)

    # Second batch: slots should be free for reuse.
    var d3 = _payload(3)
    var d4 = _payload(4)
    sink.push(Span(d3), addr)
    sink.push(Span(d4), addr)
    _ = sink.flush()
    rounds = 0
    while sink.completed() < 4:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "second batch did not complete")
    assert_equal(sink.completed(), 4)
    assert_equal(sink.failed(), 0)

    # Drain receiver.
    for _ in range(4):
        _ = _recv_one(receiver)

    _ = sink^
    _ = loop.step(0)
    receiver.close()
    sender.close()
    _ = loop^


def test_push_flush_epoll() raises:
    """Same as `test_push_flush_completes` but forced to the EPOLL backend."""
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=16, backend=Backend.EPOLL)
    var sink = loop.datagram_sink(sender, capacity=4, max_payload=64)
    var data = _payload(99)
    sink.push(Span(data), addr)
    var submitted = sink.flush()
    assert_equal(submitted, 1)

    var rounds = 0
    while sink.completed() == 0:
        _ = loop.step(1000)
        rounds += 1
        assert_true(rounds < 200, "completion never arrived")
    assert_equal(sink.completed(), 1)
    assert_equal(sink.failed(), 0)

    var got = _recv_one(receiver)
    assert_equal(len(got), 4)
    assert_equal(Int(got[0]), ord("S"))
    assert_equal(Int(got[1]), 99)

    _ = sink^
    _ = loop.step(0)
    receiver.close()
    sender.close()
    _ = loop^


def test_sendmmsg_batch_epoll() raises:
    """Flush 3 datagrams on epoll via sendmmsg; verify all arrive."""
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=16, backend=Backend.EPOLL)
    var sink = loop.datagram_sink(sender, capacity=8, max_payload=64)
    for i in range(3):
        var d = _payload(i)
        sink.push(Span(d), addr)
    assert_equal(sink.pending(), 3)
    var submitted = sink.flush()
    assert_equal(submitted, 3, "all 3 submitted in one sendmmsg")
    # On epoll sendmmsg path, sends complete synchronously.
    assert_equal(sink.completed(), 3, "all 3 completed inline")
    assert_equal(sink.in_flight(), 0, "nothing in flight on epoll")

    for _ in range(3):
        var got = _recv_one(receiver)
        assert_equal(len(got), 4)
        assert_equal(Int(got[0]), ord("S"))

    _ = sink^
    _ = loop.step(0)
    receiver.close()
    sender.close()
    _ = loop^


def test_push_after_loop_gone(backend: Backend) raises:
    """Push on a sink whose loop was destroyed raises instead of crashing."""
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = receiver.local_addr_v4()

    var loop = WatchLoop(capacity=16, backend=backend)
    var sink = loop.datagram_sink(sender, capacity=4, max_payload=64)
    var data = _payload(1)
    sink.push(Span(data), addr)
    _ = sink.flush()
    _ = loop.step(timeout_ms=1000)

    # Destroy the loop while the sink handle survives.
    _ = sender^
    _ = receiver^
    _ = loop^

    # push() must raise, not crash.
    var got_error = False
    try:
        var data2 = _payload(2)
        sink.push(Span(data2), addr)
    except:
        got_error = True
    assert_true(got_error, "push() should raise after loop gone")

    # push_msg() must also raise.
    got_error = False
    try:
        var msg = Message(_payload(3))
        msg.set_peer(addr)
        sink.push_msg(msg^)
    except:
        got_error = True
    assert_true(got_error, "push_msg() should raise after loop gone")

    # flush() must also raise.
    got_error = False
    try:
        _ = sink.flush()
    except:
        got_error = True
    assert_true(got_error, "flush() should raise after loop gone")

    _ = sink^


def main() raises:
    test_push_flush_completes(Backend.AUTO)
    print("ok: push_flush_completes (AUTO)")
    test_push_msg_flush_completes(Backend.AUTO)
    print("ok: push_msg_flush_completes (AUTO)")
    test_slot_exhaustion_raises(Backend.AUTO)
    print("ok: slot_exhaustion_raises (AUTO)")
    test_emsgsize_on_oversized_payload(Backend.AUTO)
    print("ok: emsgsize_on_oversized_payload (AUTO)")
    test_multiple_push_flush_batch(Backend.AUTO)
    print("ok: multiple_push_flush_batch (AUTO)")
    test_sink_drop_with_in_flight(Backend.AUTO)
    print("ok: sink_drop_with_in_flight (AUTO)")
    test_slot_reuse_after_completion(Backend.AUTO)
    print("ok: slot_reuse_after_completion (AUTO)")
    test_push_after_loop_gone(Backend.AUTO)
    print("ok: push_after_loop_gone (AUTO)")
    test_push_flush_epoll()
    print("ok: push_flush_epoll (EPOLL)")
    test_sendmmsg_batch_epoll()
    print("ok: sendmmsg_batch_epoll (EPOLL)")
    print("PASS: test_datagram_sink.mojo")
