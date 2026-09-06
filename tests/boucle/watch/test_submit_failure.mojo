"""A submission the driver refuses leaves nothing behind in the loop.

On the epoll backend every fd-bound operation registers a private dup
of the socket, so a descriptor closed underneath the `Socket` makes the
driver refuse the submission with EBADF before anything is in flight.
After the raise the slab slot is released, `in_flight_count()` is 0,
the buffer or message the caller moved in comes back inside the typed
error, and `run()` returns at once.

`connect` and `connect_with_timeout` cannot be refused this way: the
epoll driver issues connect(2) first and reports EBADF through the
completion instead, so they are covered by `run()` draining them.
"""

from std.testing import assert_equal, assert_true

from boucle.drivers.backend import Backend
from boucle.error import IOError
from boucle.net import Message
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.socle.platform import EBADF, close_unchecked
from boucle.watch import FailureReason, WatchLoop


def _stale_udp() raises -> Socket:
    """Return a UDP socket whose descriptor is already closed underneath it."""
    var sock = Socket.udp_v4()
    close_unchecked(unsafe_fd=sock.raw())
    return sock^


def _forget(mut sock: Socket):
    """Make `sock` skip closing a descriptor it no longer owns."""
    sock._handle._raw = -1


def _assert_clean(ref loop: WatchLoop) raises:
    """Assert no slot is active in any slab and nothing is in flight."""
    assert_equal(loop.in_flight_count(), 0, "nothing stays in flight")
    assert_equal(loop._accepts.active(), 0)
    assert_equal(loop._connects.active(), 0)
    assert_equal(loop._recvs.active(), 0)
    assert_equal(loop._sends.active(), 0)
    assert_equal(loop._recv_msgs.active(), 0)
    assert_equal(loop._send_msgs.active(), 0)
    assert_equal(loop.pending_composites(), 0)


def test_recv_refused() raises:
    """A refused recv releases its slot."""
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    var sock = _stale_udp()
    var buf = List[UInt8](length=16, fill=7)
    var storage = Int(buf.unsafe_ptr())
    var raised = False
    var back = Optional[List[UInt8]]()
    try:
        _ = loop.recv(sock, buf^)
    except e:
        raised = True
        assert_true(e.reason == FailureReason.IO)
        assert_equal(e.error.errno_value(), EBADF)
        back = e^.take_buffer()
    _forget(sock)
    assert_true(raised, "the driver must refuse a closed descriptor")
    assert_true(Bool(back), "the buffer comes back")
    assert_equal(len(back.value()), 16)
    assert_equal(Int(back.value()[0]), 7, "bytes untouched")
    assert_equal(Int(back.value().unsafe_ptr()), storage, "same storage")
    _assert_clean(loop)
    loop.run()


def test_send_refused() raises:
    """A refused send releases its slot."""
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    var sock = _stale_udp()
    var raised = False
    var back = Optional[List[UInt8]]()
    try:
        _ = loop.send(sock, List[UInt8](length=4, fill=65))
    except e:
        raised = True
        assert_true(e.reason == FailureReason.IO)
        assert_equal(e.error.errno_value(), EBADF)
        back = e^.take_buffer()
    _forget(sock)
    assert_true(raised)
    assert_true(Bool(back), "the buffer comes back")
    assert_equal(len(back.value()), 4)
    assert_equal(Int(back.value()[3]), 65)
    _assert_clean(loop)
    loop.run()


def test_recv_msg_refused() raises:
    """A refused recv_msg releases its slot."""
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    var sock = _stale_udp()
    var raised = False
    var back = Optional[Message]()
    try:
        _ = loop.recv_msg(
            sock, Message(List[UInt8](length=32, fill=0), control_capacity=24)
        )
    except e:
        raised = True
        assert_true(e.reason == FailureReason.IO)
        assert_equal(e.error.errno_value(), EBADF)
        back = e^.take_message()
    _forget(sock)
    assert_true(raised)
    assert_true(Bool(back), "the message comes back")
    assert_equal(len(back.value().payload()), 32)
    assert_equal(back.value().control_capacity(), 24)
    _assert_clean(loop)
    loop.run()


def test_send_msg_refused() raises:
    """A refused send_msg releases its slot."""
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    var sock = _stale_udp()
    var msg = Message(List[UInt8](length=3, fill=9))
    msg.set_peer(SocketAddrV4(127, 0, 0, 1, port=9))
    var raised = False
    var back = Optional[Message]()
    try:
        _ = loop.send_msg(sock, msg^)
    except e:
        raised = True
        assert_true(e.reason == FailureReason.IO)
        assert_equal(e.error.errno_value(), EBADF)
        back = e^.take_message()
    _forget(sock)
    assert_true(raised)
    assert_true(Bool(back), "the message comes back")
    assert_equal(len(back.value().payload()), 3)
    assert_equal(Int(back.value().payload()[0]), 9)
    _assert_clean(loop)
    loop.run()


def test_accept_refused() raises:
    """A refused accept releases its slot."""
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    var sock = Socket.tcp_v4()
    close_unchecked(unsafe_fd=sock.raw())
    var raised = False
    try:
        _ = loop.accept(sock)
    except e:
        raised = IOError.from_error(e).errno_value() == EBADF
    _forget(sock)
    assert_true(raised, "accept reports the driver's EBADF")
    _assert_clean(loop)
    loop.run()


def test_send_to_and_recv_from_refused() raises:
    """The datagram wrappers hand the buffer back inside the message."""
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    var sock = _stale_udp()
    var to = SocketAddrV4(127, 0, 0, 1, port=9)
    var back = Optional[Message]()
    try:
        _ = loop.send_to(sock, List[UInt8](length=2, fill=1), to)
    except e:
        back = e^.take_message()
    assert_true(Bool(back))
    assert_equal(len(back.value().payload()), 2)
    back = None
    try:
        _ = loop.recv_from(sock, List[UInt8](length=8, fill=0))
    except e:
        back = e^.take_message()
    _forget(sock)
    assert_true(Bool(back))
    assert_equal(len(back.value().payload()), 8)
    _assert_clean(loop)
    loop.run()


def test_closed_socket_handle_is_refused_before_allocation() raises:
    """A `Socket` already closed raises EBADF from the handle, buffer back, no slot."""
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    var sock = Socket.udp_v4()
    sock.close()
    var back = Optional[List[UInt8]]()
    try:
        _ = loop.recv(sock, List[UInt8](length=5, fill=3))
    except e:
        assert_equal(e.error.errno_value(), EBADF)
        back = e^.take_buffer()
    assert_true(Bool(back))
    assert_equal(len(back.value()), 5)
    _assert_clean(loop)


def main() raises:
    test_recv_refused()
    test_send_refused()
    test_recv_msg_refused()
    test_send_msg_refused()
    test_accept_refused()
    test_send_to_and_recv_from_refused()
    test_closed_socket_handle_is_refused_before_allocation()
    print("PASS: test_submit_failure.mojo")
