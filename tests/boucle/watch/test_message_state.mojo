"""The per-operation state behind send_msg and recv_msg, wired in a slab.

No kernel here: the state is placed in a `_Slab`, `wire()` fills the
msghdr and iovec from the slot's own fields, and the write-back path
(`set_result`) is driven by hand. The kernel round-trip is covered by
the loop tests.
"""

from std.memory import Pointer
from std.sys.info import size_of
from std.testing import assert_equal, assert_true

from boucle.net import Message
from boucle.net.addr import SocketAddrV4
from boucle.net.options import AddrFamily
from boucle.socle.platform import sockaddr_in6
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


def test_receiving_state_points_the_header_at_its_own_slot() raises:
    """A receive offers the whole name slot and the whole control area."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 6, _queue_ptr(queue))
    var payload = List[UInt8](length=64, fill=0)
    var storage = Int(payload.unsafe_ptr())
    var s = slab.alloc(_MessageState(Message(payload^, control_capacity=48), receiving=True))
    s[].wire()

    assert_equal(Int(s[]._hdr.msg_iov), Int(Pointer(to=s[]._iov)), "iov lives in the slot")
    assert_equal(Int(s[]._hdr.msg_iovlen), 1)
    assert_equal(Int(s[]._iov[0].iov_base), storage)
    assert_equal(Int(s[]._iov[0].iov_len), 64)
    assert_equal(Int(s[]._hdr.msg_name), Int(Pointer(to=s[].msg._peer.addr)), "name slot is the peer")
    assert_equal(Int(s[]._hdr.msg_namelen), size_of[sockaddr_in6]())
    assert_equal(Int(s[]._hdr.msg_control), Int(s[].msg._control.unsafe_ptr()))
    assert_equal(Int(s[]._hdr.msg_controllen), 48)
    assert_equal(Int(s[].msghdr_ptr()), Int(Pointer(to=s[]._hdr)))

    # The kernel writes back: 5 bytes, a 16-byte v4 name, 24 control bytes.
    s[]._hdr.msg_namelen = 16
    s[]._hdr.msg_controllen = 24
    s[]._hdr.msg_flags = 32
    s[].set_result(5)
    s[].notify_done()
    assert_true(s[].is_done())
    assert_equal(s[]._result, 5)
    assert_equal(Int(s[].msg._peer.addr_len()), 16, "peer length follows msg_namelen")
    assert_equal(s[].msg._control_received, 24, "control length follows msg_controllen")
    assert_equal(s[].msg._control_appended, 0, "nothing of it goes out on a send")
    assert_equal(Int(s[].flags()), 32)

    var back = s[].take_message()
    assert_equal(Int(back.payload().unsafe_ptr()), storage, "payload identity preserved")
    s[].mark_owner_dropped()
    assert_equal(len(queue), 1)
    assert_equal(queue[0] & ((1 << _KIND_BITS) - 1), 6)
    slab.settle(queue[0] >> _KIND_BITS)


def test_sending_state_offers_only_what_is_set() raises:
    """A send names the peer only when set and control only when non-empty."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 7, _queue_ptr(queue))

    var bare = slab.alloc(_MessageState(Message(List[UInt8](length=3, fill=1)), receiving=False))
    bare[].wire()
    assert_equal(Int(bare[]._hdr.msg_name), 0, "no peer: no name")
    assert_equal(Int(bare[]._hdr.msg_namelen), 0)
    assert_equal(Int(bare[]._hdr.msg_control), 0, "no records: no control")
    assert_equal(Int(bare[]._hdr.msg_controllen), 0)
    assert_equal(Int(bare[]._iov[0].iov_len), 3)

    var msg = Message(List[UInt8](length=3, fill=1), control_capacity=24)
    msg.set_peer(SocketAddrV4(127, 0, 0, 1, port=7))
    msg.set_ecn(1)
    var addressed = slab.alloc(_MessageState(msg^, receiving=False))
    addressed[].wire()
    assert_equal(Int(addressed[]._hdr.msg_name), Int(Pointer(to=addressed[].msg._peer.addr)))
    assert_equal(Int(addressed[]._hdr.msg_namelen), 16)
    assert_equal(Int(addressed[]._hdr.msg_controllen), 24, "one record")

    # A send completion does not touch the peer or control lengths.
    addressed[]._hdr.msg_namelen = 0
    addressed[].set_result(3)
    addressed[].notify_done()
    assert_equal(Int(addressed[].msg._peer.addr_len()), 16)
    assert_true(addressed[].msg.peer_family() == AddrFamily.INET)

    bare[].mark_owner_dropped()
    addressed[].mark_owner_dropped()
    bare[].set_result(3)
    bare[].notify_done()
    assert_equal(len(queue), 2, "both slots settle once dropped and done")
    slab.detach_all()


def test_abandon_buffer_parks_the_message() raises:
    """`abandon_buffer` leaves an empty message behind; the slot can be released."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 6, _queue_ptr(queue))
    var s = slab.alloc(_MessageState(Message(List[UInt8](length=8, fill=2), control_capacity=8), receiving=True))
    s[].wire()
    s[].abandon_buffer()
    assert_equal(len(s[].msg.payload()), 0, "the in-flight payload is parked, not freed")
    assert_equal(s[].msg.control_capacity(), 0)
    s[].mark_owner_dropped()
    slab.detach_all()
    assert_true(not slab._leaked)
    assert_equal(len(queue), 0, "the operation never completed: nothing to settle")


def test_receiving_state_with_no_control_capacity_offers_none() raises:
    """A receive with zero control capacity offers no control area at all."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 6, _queue_ptr(queue))
    var s = slab.alloc(_MessageState(Message(List[UInt8](length=4, fill=0)), receiving=True))
    s[].wire()
    assert_equal(Int(s[]._hdr.msg_control), 0, "no capacity: no control area")
    assert_equal(Int(s[]._hdr.msg_controllen), 0)
    s[].mark_owner_dropped()
    slab.detach_all()
    assert_equal(len(queue), 0, "the operation never completed: nothing to settle")


def test_sending_state_with_unused_control_capacity_offers_none() raises:
    """A send with reserved but unwritten control capacity offers no control area."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 7, _queue_ptr(queue))
    var msg = Message(List[UInt8](length=3, fill=1), control_capacity=24)
    var s = slab.alloc(_MessageState(msg^, receiving=False))
    s[].wire()
    assert_equal(Int(s[]._hdr.msg_control), 0, "capacity reserved but unused: no control area")
    assert_equal(Int(s[]._hdr.msg_controllen), 0)
    s[].mark_owner_dropped()
    slab.detach_all()
    assert_equal(len(queue), 0, "the operation never completed: nothing to settle")


def test_wiring_a_receive_clears_the_previous_peer() raises:
    """A reused message never carries the previous peer into a receive:
    `wire()` zeroes the name slot, so a receive that writes no name
    (connected socket, `msg_namelen` 0) reports UNSPEC, not the old peer."""
    var queue = List[Int]()
    var slab = _Slab[_MessageState](2, 6, _queue_ptr(queue))
    var msg = Message(List[UInt8](length=4, fill=0))
    msg.set_peer(SocketAddrV4(10, 1, 2, 3, port=4444))
    var s = slab.alloc(_MessageState(msg^, receiving=True))
    s[].wire()
    assert_equal(Int(s[].msg._peer.addr_len()), 0, "the slot length is reset")
    assert_true(s[].msg.peer_family() == AddrFamily.UNSPEC)
    var bytes = Pointer(to=s[].msg._peer.addr).unsafe_bitcast[UInt8]()
    for i in range(size_of[sockaddr_in6]()):
        assert_equal(Int(bytes[unsafe_offset=i]), 0, "the slot bytes are zero")
    assert_equal(Int(s[]._hdr.msg_name), Int(Pointer(to=s[].msg._peer.addr)))
    assert_equal(Int(s[]._hdr.msg_namelen), size_of[sockaddr_in6]())

    # The kernel wrote no name at all.
    s[]._hdr.msg_namelen = 0
    s[].set_result(4)
    s[].notify_done()
    assert_true(
        s[].msg.peer_family() == AddrFamily.UNSPEC,
        "no name written: UNSPEC, not the previous peer",
    )
    s[].mark_owner_dropped()
    slab.settle(queue[0] >> _KIND_BITS)


def main() raises:
    test_receiving_state_points_the_header_at_its_own_slot()
    print("ok: receiving state points the header at its own slot")
    test_sending_state_offers_only_what_is_set()
    print("ok: sending state offers only what is set")
    test_abandon_buffer_parks_the_message()
    print("ok: abandon_buffer parks the message")
    test_receiving_state_with_no_control_capacity_offers_none()
    print("ok: receiving state with no control capacity offers none")
    test_sending_state_with_unused_control_capacity_offers_none()
    print("ok: sending state with unused control capacity offers none")
    test_wiring_a_receive_clears_the_previous_peer()
    print("ok: wiring a receive clears the previous peer")
    print("PASS: test_message_state.mojo")
