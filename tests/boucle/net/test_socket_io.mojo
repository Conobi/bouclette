"""Tests for Socket.recv() and Socket.send().

Uses socketpair(AF_UNIX) to create a connected socket pair, bypassing
bind/listen/connect. Both ends are blocking, so send/recv complete
without EAGAIN complications.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_true, assert_equal

from boucle.handle import OwnedHandle
from boucle.net.socket import Socket


def _socketpair() raises -> Tuple[Int32, Int32]:
    """Create a connected blocking socket pair via socketpair(2).

    Returns two file descriptors for the pair endpoints.
    """
    var sv = InlineArray[Int32, 2](fill=-1)
    var sv_p = Pointer(to=sv)
    var res = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1),  # SOCK_STREAM
        Int32(0),  # protocol
        sv_p,
    )
    if res < 0:
        raise String("socketpair failed: ", Int(res))
    return (sv[0], sv[1])


def main() raises:
    # --- Create connected socket pair ---
    var fds = _socketpair()
    var sender = Socket(OwnedHandle(raw=fds[0]))
    var receiver = Socket(OwnedHandle(raw=fds[1]))

    # --- Send "ping" from sender ---
    var msg = String("ping")
    var sent = sender.send(msg.as_bytes())
    assert_equal(sent, 4, "should send 4 bytes")

    # --- Recv on receiver ---
    var buf = InlineArray[UInt8, 64](fill=0)
    var received = receiver.recv(Span(buf))
    assert_equal(received, 4, "should receive 4 bytes")

    # --- Verify content byte-by-byte ---
    assert_equal(buf[0], UInt8(ord("p")), "byte 0 should be 'p'")
    assert_equal(buf[1], UInt8(ord("i")), "byte 1 should be 'i'")
    assert_equal(buf[2], UInt8(ord("n")), "byte 2 should be 'n'")
    assert_equal(buf[3], UInt8(ord("g")), "byte 3 should be 'g'")

    # --- Test zero-length send ---
    var empty = InlineArray[UInt8, 1](fill=0)
    var empty_span = Span[UInt8, ImmStaticOrigin](
        unsafe_ptr=Pointer[UInt8, ImmStaticOrigin](
            unsafe_from_address=Int(empty.unsafe_ptr())
        ),
        length=0,
    )
    var sent_zero = sender.send(empty_span)
    assert_equal(sent_zero, 0, "zero-length send should return 0")

    # --- Test peer-closed recv returns 0 ---
    sender.close()
    var after_close = receiver.recv(Span(buf))
    assert_equal(after_close, 0, "recv after peer close should return 0")

    print("PASS: Socket.recv() and Socket.send()")
