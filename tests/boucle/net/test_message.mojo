"""ControlMessages, the cmsghdr record walker, and the owned `Message` type.

The walker is checked against hand-built cmsghdr records so the offsets
and the 8-byte record alignment are pinned independently of what the
kernel produces; the kernel round-trip lives in the watch tests.

`Message` tests here cover the payload, peer slot and control area in
isolation, without any syscall; the sendmsg/recvmsg wiring lives in the
watch tests.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.net import ControlMessages, Message, MessageResult
from boucle.net.addr import SocketAddrV4, SocketAddrV6
from boucle.net.options import AddrFamily
from boucle.socle.platform import (
    EAFNOSUPPORT,
    EINVAL,
    IP_TOS,
    IPV6_TCLASS,
    MSG_CTRUNC,
    MSG_TRUNC,
    SOL_IP,
    SOL_IPV6,
)


def _put_u64(mut buf: List[UInt8], at: Int, value: UInt64):
    """Store a little-endian UInt64 at byte offset `at`.

    Args:
        buf: The byte buffer.
        at: The offset of the first byte.
        value: The value to store.
    """
    buf.unsafe_ptr().unsafe_offset(at).unsafe_bitcast[UInt64]().unsafe_store[
        alignment=1
    ](value)


def _put_i32(mut buf: List[UInt8], at: Int, value: Int32):
    """Store a little-endian Int32 at byte offset `at`.

    Args:
        buf: The byte buffer.
        at: The offset of the first byte.
        value: The value to store.
    """
    buf.unsafe_ptr().unsafe_offset(at).unsafe_bitcast[Int32]().unsafe_store[
        alignment=1
    ](value)


def _two_records() -> List[UInt8]:
    """Build an IP_TOS record (1 data byte) then an IPV6_TCLASS record (int).

    Each record is 16 bytes of header plus data, padded to 8 bytes: the
    first occupies 0..24, the second 24..48.

    Returns:
        48 bytes holding both records.
    """
    var buf = List[UInt8](length=48, fill=0)
    _put_u64(buf, 0, 17)
    _put_i32(buf, 8, Int32(SOL_IP))
    _put_i32(buf, 12, Int32(IP_TOS))
    buf[16] = 0xE2  # DSCP 56, ECN 2
    _put_u64(buf, 24, 20)
    _put_i32(buf, 32, Int32(SOL_IPV6))
    _put_i32(buf, 36, Int32(IPV6_TCLASS))
    _put_i32(buf, 40, 3)
    return buf^


def test_walker_yields_each_record() raises:
    """Two records walk as two ControlMessages with level, type and data."""
    var buf = _two_records()
    var levels = List[Int32]()
    var types = List[Int32]()
    var sizes = List[Int]()
    var count = 0
    for cm in ControlMessages(Span(buf)):
        levels.append(cm.level)
        types.append(cm.type)
        sizes.append(len(cm.data()))
        if count == 0:
            # Record 1: the single TOS byte written at buf[16].
            assert_equal(cm.data()[0], 0xE2)
        else:
            # Record 2: the little-endian int32 `3` written at buf[40:44].
            assert_equal(cm.data()[0], 3)
            assert_equal(cm.data()[1], 0)
            assert_equal(cm.data()[2], 0)
            assert_equal(cm.data()[3], 0)
        count += 1
    assert_equal(len(levels), 2)
    assert_equal(Int(levels[0]), SOL_IP)
    assert_equal(Int(types[0]), IP_TOS)
    assert_equal(sizes[0], 1)
    assert_equal(Int(levels[1]), SOL_IPV6)
    assert_equal(Int(types[1]), IPV6_TCLASS)
    assert_equal(sizes[1], 4)


def test_walker_stops_at_a_record_past_the_end() raises:
    """A record whose length overruns the area ends iteration."""
    var buf = _two_records()
    var short = List[UInt8]()
    for i in range(40):
        short.append(buf[i])
    var n = 0
    for _ in ControlMessages(Span(short)):
        n += 1
    assert_equal(n, 1, "the second record does not fit in 40 bytes")
    var empty = List[UInt8]()
    n = 0
    for _ in ControlMessages(Span(empty)):
        n += 1
    assert_equal(n, 0)
    var bogus = List[UInt8](length=24, fill=0)
    _put_u64(bogus, 0, 4)  # cmsg_len smaller than the header
    n = 0
    for _ in ControlMessages(Span(bogus)):
        n += 1
    assert_equal(n, 0, "a record shorter than its header ends iteration")


def _one_record_then_a_wrapping_length() -> List[UInt8]:
    """Build a valid IP_TOS record at 0..24, then a record whose `cmsg_len`
    is large enough that `_offset + cmsg_len` wraps negative in 64-bit
    two's complement arithmetic.

    Returns:
        40 bytes: the first record plus the second record's 16-byte header.
    """
    var buf = List[UInt8](length=40, fill=0)
    _put_u64(buf, 0, 17)
    _put_i32(buf, 8, Int32(SOL_IP))
    _put_i32(buf, 12, Int32(IP_TOS))
    buf[16] = 0xE2  # DSCP 56, ECN 2
    _put_u64(buf, 24, 0x7FFFFFFFFFFFFFF0)
    _put_i32(buf, 32, Int32(SOL_IP))
    _put_i32(buf, 36, Int32(IP_TOS))
    return buf^


def test_walker_stops_before_a_wrapping_record_length() raises:
    """A `cmsg_len` near Int.MAX must not wrap `_offset + cmsg_len`
    negative and slip past the overrun check."""
    var buf = _one_record_then_a_wrapping_length()
    var n = 0
    for _ in ControlMessages(Span(buf)):
        n += 1
    assert_equal(n, 1, "the wrapping record must not be yielded")
    assert_equal(Int(ControlMessages(Span(buf)).ecn().value()), 2)


def test_ecn_takes_the_first_tos_record() raises:
    """`ecn()` is the low two bits of the first IP_TOS or IPV6_TCLASS record."""
    var buf = _two_records()
    var ecn = ControlMessages(Span(buf)).ecn()
    assert_true(Bool(ecn))
    assert_equal(Int(ecn.value()), 2)

    var only_v6 = List[UInt8](length=24, fill=0)
    _put_u64(only_v6, 0, 20)
    _put_i32(only_v6, 8, Int32(SOL_IPV6))
    _put_i32(only_v6, 12, Int32(IPV6_TCLASS))
    _put_i32(only_v6, 16, 0x2B)  # low two bits: 3
    assert_equal(Int(ControlMessages(Span(only_v6)).ecn().value()), 3)

    var other = List[UInt8](length=24, fill=0)
    _put_u64(other, 0, 20)
    _put_i32(other, 8, Int32(SOL_IP))
    _put_i32(other, 12, 8)  # IP_PKTINFO, not a TOS record
    assert_true(not Bool(ControlMessages(Span(other)).ecn()))


def test_ecn_skips_a_leading_non_tos_record() raises:
    """`ecn()` walks past a non-TOS record to find the TOS record after it."""
    var buf = List[UInt8](length=48, fill=0)
    _put_u64(buf, 0, 20)
    _put_i32(buf, 8, Int32(SOL_IP))
    _put_i32(buf, 12, 8)  # IP_PKTINFO, not a TOS record
    _put_u64(buf, 24, 17)
    _put_i32(buf, 32, Int32(SOL_IP))
    _put_i32(buf, 36, Int32(IP_TOS))
    buf[40] = 0xE2  # DSCP 56, ECN 2
    assert_equal(Int(ControlMessages(Span(buf)).ecn().value()), 2)


def test_message_owns_payload_and_starts_without_peer() raises:
    """A new Message has the payload, no peer, and an empty control area."""
    var payload = List[UInt8](length=3, fill=7)
    var storage = Int(payload.unsafe_ptr())
    var msg = Message(payload^, control_capacity=32)
    assert_equal(len(msg.payload()), 3)
    assert_equal(
        Int(msg.payload().unsafe_ptr()), storage, "payload moved, not copied"
    )
    assert_true(msg.peer_family() == AddrFamily.UNSPEC)
    var n = 0
    for _ in msg.control():
        n += 1
    assert_equal(n, 0, "no control record yet")
    assert_equal(msg.control_capacity(), 32)
    var back = msg^.take_payload()
    assert_equal(Int(back.unsafe_ptr()), storage, "same storage comes back")


def test_set_peer_records_the_family() raises:
    """`set_peer` stores a v4 or v6 address; the family follows."""
    var msg = Message(List[UInt8]())
    msg.set_peer(SocketAddrV4(127, 0, 0, 1, port=4433))
    assert_true(msg.peer_family() == AddrFamily.INET)
    msg.set_peer(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=4433))
    assert_true(msg.peer_family() == AddrFamily.INET6)
    assert_equal(msg.control_capacity(), 0)


def test_payload_mutates_in_place() raises:
    """`payload()` returns a mutable reference the caller can grow."""
    var msg = Message(List[UInt8](length=2, fill=0))
    msg.payload().append(9)
    assert_equal(len(msg.payload()), 3, "payload grew in place")
    assert_equal(Int(msg.payload()[2]), 9, "the appended byte is readable")


def test_set_control_len_clamps_to_capacity() raises:
    """A kernel-reported control length past the capacity is clamped, so
    the walker never reads past the 24-byte area."""
    var msg = Message(List[UInt8](), control_capacity=24)
    msg.set_peer(SocketAddrV4(127, 0, 0, 1, port=1))
    msg.set_ecn(2)  # writes exactly one 24-byte record
    msg._set_control_len(100)
    assert_equal(msg.control_capacity(), 24, "capacity itself is unaffected")
    var n = 0
    for cm in msg.control():
        n += 1
        assert_equal(len(cm.data()), 1)
    assert_equal(n, 1, "the walker sees exactly the one 24-byte record")


def test_set_ecn_derives_the_record_from_the_peer() raises:
    """A v4 peer gets IP_TOS (1 byte); a v6 peer gets IPV6_TCLASS (int)."""
    var v4 = Message(List[UInt8](), control_capacity=24)
    v4.set_peer(SocketAddrV4(127, 0, 0, 1, port=1))
    v4.set_ecn(2)
    var records = 0
    for cm in v4.control():
        records += 1
        assert_equal(Int(cm.level), SOL_IP)
        assert_equal(Int(cm.type), IP_TOS)
        assert_equal(len(cm.data()), 1)
        assert_equal(Int(cm.data()[0]), 2)
    assert_equal(records, 1)
    assert_equal(Int(v4.control().ecn().value()), 2)

    var v6 = Message(List[UInt8](), control_capacity=24)
    v6.set_peer(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=1))
    v6.set_ecn(3)
    records = 0
    for cm in v6.control():
        records += 1
        assert_equal(Int(cm.level), SOL_IPV6)
        assert_equal(Int(cm.type), IPV6_TCLASS)
        assert_equal(len(cm.data()), 4)
        assert_equal(Int(cm.data()[0]), 3)
        assert_equal(Int(cm.data()[1]), 0)
    assert_equal(records, 1)
    assert_equal(Int(v6.control().ecn().value()), 3)


def test_set_ecn_treats_a_mapped_peer_as_v4() raises:
    """`::ffff:127.0.0.1` yields IP_TOS, never IPV6_TCLASS."""
    var msg = Message(List[UInt8](), control_capacity=24)
    msg.set_peer(SocketAddrV6(0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001, port=1))
    assert_true(msg.peer_family() == AddrFamily.INET6)
    msg.set_ecn(1)
    var records = 0
    for cm in msg.control():
        records += 1
        assert_equal(Int(cm.level), SOL_IP)
        assert_equal(Int(cm.type), IP_TOS)
    assert_equal(records, 1, "the walker must not pass vacuously")


def test_set_ecn_with_explicit_family_and_no_peer() raises:
    """No peer set: an explicit family is enough to write one record."""
    var msg = Message(List[UInt8](), control_capacity=24)
    assert_true(msg.peer_family() == AddrFamily.UNSPEC)
    msg.set_ecn(1, family=AddrFamily.INET)
    var records = 0
    for cm in msg.control():
        records += 1
        assert_equal(Int(cm.level), SOL_IP)
        assert_equal(Int(cm.type), IP_TOS)
        assert_equal(Int(cm.data()[0]), 1)
    assert_equal(records, 1)


def test_set_ecn_explicit_family_and_masking() raises:
    """An explicit family overrides the peer; only two bits are kept."""
    var msg = Message(List[UInt8](), control_capacity=48)
    msg.set_peer(SocketAddrV4(127, 0, 0, 1, port=1))
    msg.set_ecn(0xFF, family=AddrFamily.INET6)
    msg.set_ecn(0x02)
    var levels = List[Int32]()
    for cm in msg.control():
        levels.append(cm.level)
    assert_equal(len(levels), 2)
    assert_equal(Int(levels[0]), SOL_IPV6)
    assert_equal(Int(levels[1]), SOL_IP)
    assert_equal(Int(msg.control().ecn().value()), 3, "0xFF masked to 3")


def test_set_ecn_raises_einval_without_family_or_room() raises:
    """No peer and no family, or a full control area, is EINVAL."""
    var no_family = Message(List[UInt8](), control_capacity=24)
    var caught = False
    try:
        no_family.set_ecn(1)
    except e:
        caught = e.errno_value() == EINVAL
    assert_true(caught, "no peer and no family: EINVAL")

    var no_room = Message(List[UInt8](), control_capacity=16)
    no_room.set_peer(SocketAddrV4(127, 0, 0, 1, port=1))
    caught = False
    try:
        no_room.set_ecn(1)
    except e:
        caught = e.errno_value() == EINVAL
    assert_true(caught, "a 24-byte record does not fit in 16: EINVAL")
    var n = 0
    for _ in no_room.control():
        n += 1
    assert_equal(n, 0, "nothing was written")


def test_message_result_exposes_count_peer_and_flags() raises:
    """`count`, transferred(), the decoded peer, the flags, and the message back.
    """
    var msg = Message(List[UInt8](length=8, fill=0x41), control_capacity=24)
    msg.set_peer(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=9))
    var storage = Int(msg.payload().unsafe_ptr())
    var r = MessageResult(3, msg^, Int32(MSG_TRUNC))
    assert_equal(r.count, 3)
    assert_equal(len(r.transferred()), 3)
    assert_equal(Int(r.transferred()[0]), 0x41)
    assert_true(r.truncated())
    assert_true(not r.control_truncated())
    assert_true(r.peer_family() == AddrFamily.INET6)
    var peer = r.peer_v6()
    assert_equal(peer.port, UInt16(9))
    assert_equal(Int(peer.segments()[7]), 1)
    var wrong = False
    try:
        _ = r.peer_v4()
    except e:
        wrong = e.errno_value() == EAFNOSUPPORT
    assert_true(wrong, "peer_v4 on a v6 peer is EAFNOSUPPORT")
    var n = 0
    for _ in r.control():
        n += 1
    assert_equal(n, 0)
    var back = r^.take_message()
    assert_equal(Int(back.payload().unsafe_ptr()), storage, "same storage")


def test_message_result_v4_peer_and_ctrunc() raises:
    """A v4 peer decodes with peer_v4; MSG_CTRUNC surfaces as control_truncated.
    """
    var msg = Message(List[UInt8](length=2, fill=0))
    msg.set_peer(SocketAddrV4(10, 1, 2, 3, port=53))
    var r = MessageResult(2, msg^, Int32(MSG_CTRUNC))
    assert_true(not r.truncated())
    assert_true(r.control_truncated())
    var peer = r.peer_v4()
    assert_equal(Int(peer.ip.octets[0]), 10)
    assert_equal(Int(peer.ip.octets[3]), 3)
    assert_equal(peer.port, UInt16(53))
    var wrong = False
    try:
        _ = r.peer_v6()
    except e:
        wrong = e.errno_value() == EAFNOSUPPORT
    assert_true(wrong)

    var nameless = MessageResult(0, Message(List[UInt8]()), 0)
    assert_true(nameless.peer_family() == AddrFamily.UNSPEC)
    wrong = False
    try:
        _ = nameless.peer_v4()
    except e:
        wrong = e.errno_value() == EAFNOSUPPORT
    assert_true(wrong, "no name written: EAFNOSUPPORT")


def main() raises:
    test_walker_yields_each_record()
    test_walker_stops_at_a_record_past_the_end()
    test_walker_stops_before_a_wrapping_record_length()
    test_ecn_takes_the_first_tos_record()
    test_ecn_skips_a_leading_non_tos_record()
    test_message_owns_payload_and_starts_without_peer()
    test_set_peer_records_the_family()
    test_payload_mutates_in_place()
    test_set_control_len_clamps_to_capacity()
    test_set_ecn_derives_the_record_from_the_peer()
    test_set_ecn_treats_a_mapped_peer_as_v4()
    test_set_ecn_with_explicit_family_and_no_peer()
    test_set_ecn_explicit_family_and_masking()
    test_set_ecn_raises_einval_without_family_or_room()
    test_message_result_exposes_count_peer_and_flags()
    test_message_result_v4_peer_and_ctrunc()
    print("PASS: test_message.mojo")
