"""Test RecvFuture, SendFuture and WatchLoop.recv()/send().

Creates a connected AF_UNIX socketpair, submits async send and recv
via WatchLoop, then verifies the data arrives correctly.

Note: uses direct syscalls for socket setup due to a Mojo 1.0.0
compiler bug affecting Socket.bind() through parametric inlining.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.sys.info import size_of
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

    var loop = WatchLoop(sq_entries=8)

    # Send "ping" from sock_a.
    var msg = String("ping")
    var send_buf = msg.as_bytes()
    var send_f = loop.send(sock_a, send_buf)

    # Recv into buffer on sock_b.
    var recv_buf = InlineArray[UInt8, 64](fill=UInt8(0))
    var recv_span = Span[UInt8, MutAnyOrigin](
        unsafe_ptr=Pointer[UInt8, MutAnyOrigin](
            unsafe_from_address=Int(Pointer(to=recv_buf))
        ),
        length=64,
    )
    var recv_f = loop.recv(sock_b, recv_span)

    loop.run()

    assert_true(send_f.done(), "send should be done after run()")
    assert_true(recv_f.done(), "recv should be done after run()")

    var sent = send_f.result()
    var received = recv_f.result()
    assert_equal(sent, 4, "should have sent 4 bytes")
    assert_equal(received, 4, "should have received 4 bytes")

    # Verify buffer content matches "ping".
    assert_equal(recv_buf[0], UInt8(ord("p")), "byte 0 should be 'p'")
    assert_equal(recv_buf[1], UInt8(ord("i")), "byte 1 should be 'i'")
    assert_equal(recv_buf[2], UInt8(ord("n")), "byte 2 should be 'n'")
    assert_equal(recv_buf[3], UInt8(ord("g")), "byte 3 should be 'g'")

    sock_a.close()
    sock_b.close()


def main() raises:
    test_send_recv_basic()
    print("RecvFuture/SendFuture tests passed.")
