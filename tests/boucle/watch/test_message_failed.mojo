"""`recv_msg` on a never-connected TCP socket fails with ENOTCONN and gives the message back.

A UDP socket shut down for reading is not usable here: recvmsg then
returns 0, not an errno. The IO path is checked on both backends;
NOT_DONE and LOOP_GONE return no message.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.error import IOError
from boucle.handle import OwnedHandle
from boucle.net import Message, Socket
from boucle.socle.linux.errno import get_errno
from boucle.socle.platform import ECANCELED, EINVAL, ENOTCONN
from boucle.watch import Backend, FailureReason, WatchLoop


def _make_socketpair() raises -> Tuple[Int32, Int32]:
    """Create a connected, non-blocking AF_UNIX SOCK_DGRAM socketpair.

    Returns:
        The two raw fds; the caller wraps them in Socket.
    """
    var fds = InlineArray[Int32, 2](fill=Int32(0))
    var fds_p = Pointer(to=fds)
    var res = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(2 | 2048 | 524288),  # SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC
        Int32(0),
        fds_p,
    )
    if res < 0:
        raise String("socketpair failed: errno ", Int(get_errno()))
    return (fds[0], fds[1])


def _io_failure_returns_the_message(backend: Backend) raises:
    """ENOTCONN completes the recvmsg; reason IO; the payload list comes back.

    Args:
        backend: The loop backend to force.
    """
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8, backend=backend)
    var payload = List[UInt8](length=16, fill=0x33)
    var storage = Int(payload.unsafe_ptr())
    var recv_f = loop.recv_msg(sock, Message(payload^, control_capacity=24))
    loop.run()
    assert_true(recv_f.done())

    var reason = FailureReason.NOT_DONE
    var error = IOError(positive_errno=0)
    var back = Optional[Message]()
    try:
        _ = recv_f^.result()
    except e:
        reason = e.reason
        error = e.error
        back = e^.take_message()
    assert_true(reason == FailureReason.IO)
    assert_equal(error.errno_value(), ENOTCONN)
    assert_true(Bool(back), "the message comes back on IO failure")
    var msg = back.take()
    assert_equal(msg.control_capacity(), 24, "control area intact")
    var list = msg^.take_payload()
    assert_equal(len(list), 16)
    assert_equal(Int(list[0]), 0x33, "bytes untouched")
    assert_equal(Int(list.unsafe_ptr()), storage, "same storage")
    sock.close()


def test_not_done_returns_no_message() raises:
    """`result()` before run() is NOT_DONE with EINVAL and no message; run() drains."""
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8)
    var recv_f = loop.recv_msg(sock, Message(List[UInt8](length=8, fill=0)))

    var reason = FailureReason.IO
    var errno = 0
    var back = Optional[Message](Message(List[UInt8]()))
    try:
        _ = recv_f^.result()
    except e:
        reason = e.reason
        errno = e.error.errno_value()
        back = e^.take_message()
    assert_true(reason == FailureReason.NOT_DONE)
    assert_equal(errno, EINVAL)
    assert_true(not Bool(back))
    assert_equal(loop.in_flight_count(), 1, "the loop still owns the message")

    loop.run()
    assert_equal(loop.in_flight_count(), 0)
    sock.close()


def test_loop_gone_returns_no_message() raises:
    """A future outliving its loop is LOOP_GONE with ECANCELED and no message."""
    var fds = _make_socketpair()
    var reader = Socket(OwnedHandle(raw=fds[0]))
    var writer = Socket(OwnedHandle(raw=fds[1]))
    var loop = WatchLoop()
    var recv_f = loop.recv_msg(reader, Message(List[UInt8](length=8, fill=0)))
    _ = loop^

    assert_true(not recv_f.done())
    var reason = FailureReason.IO
    var errno = 0
    var back = Optional[Message](Message(List[UInt8]()))
    try:
        _ = recv_f^.result()
    except e:
        reason = e.reason
        errno = e.error.errno_value()
        back = e^.take_message()
    assert_true(reason == FailureReason.LOOP_GONE)
    assert_equal(errno, ECANCELED)
    assert_true(not Bool(back), "an abandoned message is not handed back")

    reader.close()
    writer.close()


def main() raises:
    _io_failure_returns_the_message(Backend.AUTO)
    _io_failure_returns_the_message(Backend.EPOLL)
    print("ok: IO failure returns the message on both backends")
    test_not_done_returns_no_message()
    print("ok: NOT_DONE returns no message")
    test_loop_gone_returns_no_message()
    print("ok: LOOP_GONE returns no message")
    print("PASS: test_message_failed.mojo")
