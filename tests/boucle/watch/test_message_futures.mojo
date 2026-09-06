"""RecvMsgFuture / SendMsgFuture over a bare slab, no kernel involved.

The completion is delivered by hand — `set_result` then `notify_done` —
so every `result()` path can be pinned without a socket: a successful
receive decodes into a `MessageResult`, a failed one raises
`MessageFailed` carrying the same message back, and NOT_DONE / LOOP_GONE
carry nothing. The same paths driven by a real loop over UDP loopback
live in test_recv_msg_send_msg.mojo.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.net import Message
from boucle.net.addr import SocketAddrV4
from boucle.net.options import AddrFamily
from boucle.socle.platform import ECANCELED, EINVAL, ENOTCONN, MSG_TRUNC
from boucle.watch import FailureReason, RecvMsgFuture, SendMsgFuture
from boucle.watch._callback import _KIND_BITS
from boucle.watch._message import _MessageState
from boucle.watch._slab import _Slab


def _queue_ptr(ref queue: List[Int]) -> Pointer[List[Int], MutUntrackedOrigin]:
    """Return an untracked pointer to a settle queue owned by the caller.

    Args:
        queue: The list standing in for the loop's settle queue.
    """
    return Pointer[List[Int], MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=queue))
    )


def test_result_before_completion_is_not_done() raises:
    """`result()` on a pending future is NOT_DONE, returns no message, drops the handle."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 6, _queue_ptr(queue))
    var s = slab.alloc(_MessageState(Message(List[UInt8](length=4, fill=0)), receiving=True))
    s[].wire()
    var f = RecvMsgFuture(s)
    assert_true(not f.done())

    var reason = FailureReason.IO
    var errno = 0
    var back = Optional[Message](Message(List[UInt8]()))
    try:
        _ = f^.result()
    except e:
        reason = e.reason
        errno = e.error.errno_value()
        back = e^.take_message()
    assert_true(reason == FailureReason.NOT_DONE)
    assert_equal(errno, EINVAL)
    assert_true(not Bool(back), "the message is still in flight")
    assert_true(s[].owner_dropped(), "result() consumed the handle")
    assert_equal(len(queue), 0, "not done yet: nothing to settle")

    s[].set_result(4)
    s[].notify_done()
    assert_equal(len(queue), 1, "completion is the second event")
    slab.settle(queue[0] >> _KIND_BITS)


def test_result_after_loop_gone_is_loop_gone() raises:
    """A future outliving its loop reports LOOP_GONE and frees the state itself."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 7, _queue_ptr(queue))
    var s = slab.alloc(_MessageState(Message(List[UInt8](length=4, fill=0)), receiving=False))
    s[].wire()
    var f = SendMsgFuture(s)
    s[].abandon_buffer()  # what the loop's destructor does first
    slab.detach_all()     # ... then marks the held slot loop_gone
    assert_true(s[].loop_gone())

    var reason = FailureReason.IO
    var errno = 0
    var back = Optional[Message](Message(List[UInt8]()))
    try:
        _ = f^.result()
    except e:
        reason = e.reason
        errno = e.error.errno_value()
        back = e^.take_message()
    assert_true(reason == FailureReason.LOOP_GONE)
    assert_equal(errno, ECANCELED)
    assert_true(not Bool(back), "an abandoned message is not handed back")
    assert_true(slab._leaked, "the chunk stays allocated for the handle that read it")


def test_dropping_a_done_future_queues_the_slot() raises:
    """Drop after completion pushes the key; drop before does not."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 6, _queue_ptr(queue))
    var a = slab.alloc(_MessageState(Message(List[UInt8]()), receiving=True))
    a[].wire()
    a[].set_result(0)
    a[].notify_done()
    var fa = RecvMsgFuture(a)
    assert_true(fa.done())
    _ = fa^
    assert_equal(len(queue), 1)

    var b = slab.alloc(_MessageState(Message(List[UInt8]()), receiving=True))
    b[].wire()
    var fb = RecvMsgFuture(b)
    _ = fb^
    assert_equal(len(queue), 1, "dropped before done: queued by the completion later")
    b[].set_result(0)
    b[].notify_done()
    assert_equal(len(queue), 2)
    for key in queue:
        slab.settle(key >> _KIND_BITS)
    assert_equal(len(slab._free), 2)


def test_result_after_receive_decodes_the_message() raises:
    """A completed receive yields count, flags and the peer; the slot is queued once."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 6, _queue_ptr(queue))
    var payload = List[UInt8](length=8, fill=0)
    var storage = Int(payload.unsafe_ptr())
    var s = slab.alloc(
        _MessageState(Message(payload^, control_capacity=24), receiving=True)
    )
    s[].wire()
    var f = RecvMsgFuture(s)

    # What the kernel writes back for a 5-byte datagram from 10.1.2.3:4444
    # whose 12-byte datagram did not fit the 8-byte window.
    var sender = SocketAddrV4(10, 1, 2, 3, port=4444)
    s[].msg.set_peer(sender)
    s[]._hdr.msg_namelen = 16
    s[]._hdr.msg_controllen = 0
    s[]._hdr.msg_flags = MSG_TRUNC
    s[].set_result(12)
    s[].notify_done()
    assert_true(f.done())
    assert_equal(len(queue), 0, "handle still held: nothing to settle")

    var got = f^.result()
    assert_equal(got.count, 12, "the kernel reports the full datagram length")
    assert_equal(len(got.transferred()), 8, "transferred() clamps to the window")
    assert_true(got.truncated())
    assert_true(not got.control_truncated())
    assert_true(got.peer_family() == AddrFamily.INET)
    var peer = got.peer_v4()
    assert_equal(Int(peer.ip.octets[0]), 10)
    assert_equal(Int(peer.ip.octets[3]), 3)
    assert_equal(Int(peer.port), 4444)
    var back = got^.take_message()
    assert_equal(Int(back.payload().unsafe_ptr()), storage, "payload identity preserved")
    assert_equal(len(queue), 1, "result() let go of a done slot: queued exactly once")
    slab.settle(queue[0] >> _KIND_BITS)
    assert_equal(len(slab._free), 2)


def test_result_after_failed_receive_is_io_with_the_message() raises:
    """A negative completion raises IO and hands the very same payload back."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 6, _queue_ptr(queue))
    var payload = List[UInt8](length=16, fill=7)
    var storage = Int(payload.unsafe_ptr())
    var s = slab.alloc(_MessageState(Message(payload^), receiving=True))
    s[].wire()
    var f = RecvMsgFuture(s)
    s[].set_result(-ENOTCONN)
    s[].notify_done()

    var reason = FailureReason.NOT_DONE
    var errno = 0
    var back = Optional[Message](None)
    try:
        _ = f^.result()
    except e:
        reason = e.reason
        errno = e.error.errno_value()
        back = e^.take_message()
    assert_true(reason == FailureReason.IO)
    assert_equal(errno, ENOTCONN)
    assert_true(Bool(back), "an IO failure carries the message")
    var msg = back.take()
    assert_equal(len(msg.payload()), 16, "payload length unchanged")
    assert_equal(Int(msg.payload().unsafe_ptr()), storage, "same allocation")
    assert_equal(len(queue), 1, "the failed slot is queued exactly once")
    slab.settle(queue[0] >> _KIND_BITS)


def main() raises:
    test_result_after_receive_decodes_the_message()
    print("ok: result after a receive decodes the message")
    test_result_after_failed_receive_is_io_with_the_message()
    print("ok: result after a failed receive is IO with the message")
    test_result_before_completion_is_not_done()
    print("ok: result before completion is NOT_DONE")
    test_result_after_loop_gone_is_loop_gone()
    print("ok: result after loop gone is LOOP_GONE")
    test_dropping_a_done_future_queues_the_slot()
    print("ok: dropping a done future queues the slot")
    print("PASS: test_message_futures.mojo")
