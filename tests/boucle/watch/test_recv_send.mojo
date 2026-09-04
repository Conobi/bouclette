"""Test RecvFuture, SendFuture and WatchLoop.recv()/send().

Creates a connected AF_UNIX socketpair, submits async send and recv
via WatchLoop, then verifies the data arrives correctly.

socketpair(2) is called directly: it is the only socket constructor
boucle.net.Socket does not wrap, and a pre-connected pair keeps the test
free of accept/connect machinery.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.watch import WatchLoop, RecvFuture, SendFuture
from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.socle.linux.errno import get_errno


def _make_socketpair() raises -> Tuple[Int32, Int32]:
    """Create a connected AF_UNIX SOCK_STREAM socketpair.

    Returns the two raw fds. Caller wraps them in Socket.
    """
    # socketpair(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, fds)
    var fds = InlineArray[Int32, 2](fill=Int32(0))
    var fds_p = Pointer(to=fds)
    var res = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1 | 2048 | 524288),  # SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
        Int32(0),  # protocol
        fds_p,
    )
    if res < 0:
        raise String("socketpair failed: errno ", Int(get_errno()))

    return (fds[0], fds[1])


def test_send_recv_basic() raises:
    """WatchLoop send+recv round-trips data through a socketpair."""
    var fds = _make_socketpair()
    var sock_a = Socket(OwnedHandle(raw=fds[0]))
    var sock_b = Socket(OwnedHandle(raw=fds[1]))

    var loop = WatchLoop(capacity=8)

    # Send "ping" from sock_a. The buffer belongs to the loop until
    # result() gives it back.
    var msg = String("ping")
    var send_buf = List[UInt8]()
    for c in msg.as_bytes():
        send_buf.append(c)
    var send_f = loop.send(sock_a, send_buf^)

    # Recv into a buffer on sock_b; its length is the readable window.
    var recv_f = loop.recv(sock_b, List[UInt8](length=64, fill=0))

    loop.run()

    assert_true(send_f.done(), "send should be done after run()")
    assert_true(recv_f.done(), "recv should be done after run()")

    var sent = send_f^.result()
    var received = recv_f^.result()
    assert_equal(sent.count, 4, "should have sent 4 bytes")
    assert_equal(received.count, 4, "should have received 4 bytes")

    # Verify buffer content matches "ping".
    assert_equal(
        String(from_utf8=received.transferred()),
        msg,
        "received bytes should equal the sent message",
    )

    sock_a.close()
    sock_b.close()


def main() raises:
    test_send_recv_basic()
    print("RecvFuture/SendFuture tests passed.")
