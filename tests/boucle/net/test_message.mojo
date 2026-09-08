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
    SOL_UDP,
    UDP_GRO,
    UDP_SEGMENT,
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


def _get_u64(buf: List[UInt8], at: Int) -> UInt64:
    """Read the little-endian UInt64 at byte offset `at`."""
    return (
        buf.unsafe_ptr()
        .unsafe_offset(at)
        .unsafe_bitcast[UInt64]()
        .unsafe_load[alignment=1]()
    )


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


def test_next_past_the_end_yields_an_empty_record() raises:
    """A manual `__next__` on an exhausted walker returns an empty record
    and never reads beyond the span, even one shorter than a header."""
    var short = List[UInt8](length=8, fill=0xFF)
    var walker = ControlMessages(Span(short))
    assert_true(not walker.__has_next__(), "8 bytes hold no header")
    var cm = walker.__next__()
    assert_equal(Int(cm.level), 0)
    assert_equal(Int(cm.type), 0)
    assert_equal(len(cm.data()), 0)
    assert_equal(walker._offset, 8, "the cursor stops at the end of the span")
    var again = walker.__next__()
    assert_equal(len(again.data()), 0, "still empty, still at the end")
    assert_equal(walker._offset, 8)

    var one = _two_records()
    var full = ControlMessages(Span(one))
    _ = full.__next__()
    _ = full.__next__()
    assert_true(not full.__has_next__())
    var past = full.__next__()
    assert_equal(len(past.data()), 0, "past the last record: empty")
    assert_equal(full._offset, 48)


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


def test_gro_segment_size_reads_the_udp_gro_record() raises:
    """`gro_segment_size()` is the int of the first SOL_UDP/UDP_GRO record."""
    var buf = List[UInt8](length=48, fill=0)
    _put_u64(buf, 0, 17)
    _put_i32(buf, 8, Int32(SOL_IP))
    _put_i32(buf, 12, Int32(IP_TOS))
    buf[16] = 0x01
    _put_u64(buf, 24, 20)
    _put_i32(buf, 32, Int32(SOL_UDP))
    _put_i32(buf, 36, Int32(UDP_GRO))
    _put_i32(buf, 40, 1350)
    var size = ControlMessages(Span(buf)).gro_segment_size()
    assert_true(Bool(size), "the record is found behind the TOS record")
    assert_equal(size.value(), 1350)
    assert_equal(
        Int(ControlMessages(Span(buf)).ecn().value()), 1, "ecn() is unaffected"
    )

    var two = _two_records()
    assert_true(
        not Bool(ControlMessages(Span(two)).gro_segment_size()),
        "no GRO record: None",
    )

    var short = List[UInt8](length=24, fill=0)
    _put_u64(short, 0, 18)  # two data bytes only
    _put_i32(short, 8, Int32(SOL_UDP))
    _put_i32(short, 12, Int32(UDP_GRO))
    short[16] = 0x46
    short[17] = 0x05
    assert_true(
        not Bool(ControlMessages(Span(short)).gro_segment_size()),
        "fewer than 4 data bytes: None",
    )

    var wrong_level = List[UInt8](length=24, fill=0)
    _put_u64(wrong_level, 0, 20)
    _put_i32(wrong_level, 8, Int32(SOL_IP))
    _put_i32(wrong_level, 12, Int32(UDP_GRO))
    _put_i32(wrong_level, 16, 600)
    assert_true(
        not Bool(ControlMessages(Span(wrong_level)).gro_segment_size()),
        "type 104 at SOL_IP is not a GRO record",
    )


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


def test_negative_control_capacity_clamps_to_zero() raises:
    """A negative control capacity reserves nothing rather than a wrapped length."""
    var msg = Message(List[UInt8](), control_capacity=-24)
    assert_equal(msg.control_capacity(), 0)
    var n = 0
    for _ in msg.control():
        n += 1
    assert_equal(n, 0)


def test_control_space_is_cmsg_space() raises:
    """`control_space` is CMSG_SPACE: 16 plus the data, rounded up to 8, saturating."""
    assert_equal(Message.control_space(0), 16)
    assert_equal(Message.control_space(1), 24)
    assert_equal(Message.control_space(2), 24)
    assert_equal(Message.control_space(4), 24)
    assert_equal(Message.control_space(8), 24)
    assert_equal(Message.control_space(9), 32)
    assert_equal(Message.control_space(-1), 16, "negative data_len counts as 0")
    assert_equal(Message.control_space(-1000), 16)
    assert_equal(
        Message.control_space(4) + Message.control_space(2),
        48,
        "an ECN record and a GSO record",
    )
    assert_equal(
        Message.control_space(Int.MAX - 23),
        Int.MAX - 7,
        "the last input that does not saturate",
    )
    assert_equal(
        Message.control_space(Int.MAX - 22), Int.MAX, "one past it saturates"
    )
    assert_equal(Message.control_space(Int.MAX), Int.MAX)


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


def test_set_control_received_clamps_to_capacity() raises:
    """A kernel-reported control length past the capacity is clamped, so
    the walker never reads past the 24-byte area."""
    var msg = Message(List[UInt8](), control_capacity=24)
    msg.set_peer(SocketAddrV4(127, 0, 0, 1, port=1))
    msg.set_ecn(2)  # writes exactly one 24-byte record
    msg._set_control_received(100)
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


def test_set_ecn_explicit_family_and_masking_stacks() raises:
    """An explicit family overrides the peer; only two bits are kept; a
    second call appends a second record behind the first, both visible."""
    var msg = Message(List[UInt8](), control_capacity=48)
    msg.set_peer(SocketAddrV4(127, 0, 0, 1, port=1))
    msg.set_ecn(0xFF, family=AddrFamily.INET6)
    var levels = List[Int32]()
    for cm in msg.control():
        levels.append(cm.level)
    assert_equal(len(levels), 1)
    assert_equal(Int(levels[0]), SOL_IPV6)
    assert_equal(Int(msg.control().ecn().value()), 3, "0xFF masked to 3")
    msg.set_ecn(0x02)
    levels = List[Int32]()
    for cm in msg.control():
        levels.append(cm.level)
    assert_equal(len(levels), 2, "stacked, both visible")
    assert_equal(Int(levels[0]), SOL_IPV6)
    assert_equal(Int(levels[1]), SOL_IP)
    assert_equal(
        Int(msg.control().ecn().value()), 3, "the reader takes the first record"
    )
    assert_equal(msg._control_appended, 48, "both records are offered to a send")
    var errno = 0
    try:
        msg.set_ecn(1)
    except e:
        errno = e.errno_value()
    assert_equal(errno, EINVAL, "a third record does not fit in 48")
    assert_equal(msg._control_appended, 48, "the refused call changed nothing")


def _receive_one_tos_record(mut msg: Message, tos: UInt8):
    """Write an `IP_TOS` record into `msg`'s control area the way a
    receive does: bytes in place, then the kernel-reported length.

    Args:
        msg: A message with at least 24 bytes of control capacity.
        tos: The TOS byte the record carries.
    """
    _put_u64(msg._control, 0, 17)
    _put_i32(msg._control, 8, Int32(SOL_IP))
    _put_i32(msg._control, 12, Int32(IP_TOS))
    msg._control[16] = tos
    msg._set_control_received(24)


def test_a_send_offers_only_the_appended_records() raises:
    """Kernel-written records are never offered to a send: after a receive
    the appended length is 0, the first `set_ecn` starts the builder over
    at the front of the area, a later append stacks behind it, and
    `clear_control` drops both lengths."""
    var msg = Message(List[UInt8](), control_capacity=48)
    msg.set_peer(SocketAddrV4(127, 0, 0, 1, port=1))
    _receive_one_tos_record(msg, 0xE0)
    assert_equal(msg._control_received, 24, "the kernel wrote one record")
    assert_equal(msg._control_appended, 0, "nothing goes out on a send")
    var n = 0
    for cm in msg.control():
        n += 1
        assert_equal(Int(cm.data()[0]), 0xE0)
    assert_equal(n, 1, "the received record is readable")

    msg.set_ecn(1)
    assert_equal(msg._control_appended, 24, "one record to send")
    assert_equal(msg._control_received, 0, "the received record is gone")
    n = 0
    for cm in msg.control():
        n += 1
        assert_equal(Int(cm.level), SOL_IP)
        assert_equal(Int(cm.data()[0]), 1, "ECN 1, DSCP 0: not the peer's byte")
    assert_equal(n, 1)

    msg.set_ecn(2)
    assert_equal(msg._control_appended, 48, "two records to send")
    n = 0
    for cm in msg.control():
        n += 1
        assert_equal(Int(cm.level), SOL_IP)
    assert_equal(n, 2, "the second call stacked behind the first")

    msg.clear_control()
    assert_equal(msg._control_received, 0)
    assert_equal(msg._control_appended, 0)
    n = 0
    for _ in msg.control():
        n += 1
    assert_equal(n, 0, "nothing left to walk")


def test_append_control_walks_back_in_order() raises:
    """Appended records come back from the walker as the exact triples, in order."""
    var msg = Message(List[UInt8](), control_capacity=72)
    for i in range(72):
        msg._control[i] = 0xFF  # dirty, so zeroed padding is observable
    var first = List[UInt8]()
    first.append(0xAA)
    var second = List[UInt8]()
    var third = List[UInt8]()
    for i in range(9):
        third.append(UInt8(i + 1))
    msg.append_control(Int32(SOL_IP), Int32(IP_TOS), Span(first))
    msg.append_control(Int32(7), Int32(-3), Span(second))
    msg.append_control(Int32(SOL_UDP), Int32(UDP_SEGMENT), Span(third))
    assert_equal(msg._control_appended, 24 + 16 + 32)
    assert_equal(msg._control_received, 0)
    assert_equal(Int(_get_u64(msg._control, 0)), 17, "cmsg_len is unpadded")
    assert_equal(Int(_get_u64(msg._control, 24)), 16, "a zero-data record")
    assert_equal(Int(_get_u64(msg._control, 40)), 25)
    var n = 0
    for cm in msg.control():
        if n == 0:
            assert_equal(Int(cm.level), SOL_IP)
            assert_equal(Int(cm.type), IP_TOS)
            assert_equal(len(cm.data()), 1)
            assert_equal(Int(cm.data()[0]), 0xAA)
        elif n == 1:
            assert_equal(Int(cm.level), 7)
            assert_equal(Int(cm.type), -3)
            assert_equal(len(cm.data()), 0)
        else:
            assert_equal(Int(cm.level), SOL_UDP)
            assert_equal(Int(cm.type), UDP_SEGMENT)
            assert_equal(len(cm.data()), 9)
            for i in range(9):
                assert_equal(Int(cm.data()[i]), i + 1)
        n += 1
    assert_equal(n, 3, "three records, no more")
    for i in range(65, 72):
        assert_equal(Int(msg._control[i]), 0, "padding after the data is zeroed")
    for i in range(17, 24):
        assert_equal(Int(msg._control[i]), 0, "padding after the TOS byte is zeroed")


def test_append_control_overflow_is_einval_and_writes_nothing() raises:
    """A record that does not fit raises EINVAL and leaves the area untouched."""
    var msg = Message(List[UInt8](), control_capacity=44)
    for i in range(44):
        msg._control[i] = 0xCC
    var one = List[UInt8]()
    one.append(1)
    msg.append_control(Int32(SOL_IP), Int32(IP_TOS), Span(one))
    assert_equal(msg._control_appended, 24, "20 bytes left")

    var nine = List[UInt8](length=9, fill=9)
    var errno = 0
    try:
        msg.append_control(Int32(SOL_IP), Int32(IP_TOS), Span(nine))
    except e:
        errno = e.errno_value()
    assert_equal(errno, EINVAL, "16 + 9 does not fit in 20")
    assert_equal(msg._control_appended, 24, "the failed append changed nothing")
    assert_equal(msg._control_received, 0)

    var three = List[UInt8](length=3, fill=3)
    errno = 0
    try:
        msg.append_control(Int32(SOL_IP), Int32(IP_TOS), Span(three))
    except e:
        errno = e.errno_value()
    assert_equal(errno, EINVAL, "16 + 3 fits in 20 unpadded, 24 padded does not")
    assert_equal(msg._control_appended, 24)
    for i in range(24, 44):
        assert_equal(Int(msg._control[i]), 0xCC, "no byte past the first record was touched")

    var empty = List[UInt8]()
    msg.append_control(Int32(SOL_IP), Int32(IP_TOS), Span(empty))
    assert_equal(msg._control_appended, 40, "a bare header fits in 20")
    for i in range(40, 44):
        assert_equal(Int(msg._control[i]), 0xCC, "the 4 bytes left are untouched")
    errno = 0
    try:
        msg.append_control(Int32(SOL_IP), Int32(IP_TOS), Span(empty))
    except e:
        errno = e.errno_value()
    assert_equal(errno, EINVAL, "4 bytes hold no header")

    var none = Message(List[UInt8](), control_capacity=0)
    errno = 0
    try:
        none.append_control(Int32(SOL_IP), Int32(IP_TOS), Span(empty))
    except e:
        errno = e.errno_value()
    assert_equal(errno, EINVAL, "no capacity: EINVAL")
    assert_equal(none._control_appended, 0)


def test_set_gso_segment_size_appends_an_18_byte_record() raises:
    """`UDP_SEGMENT` carries a u16: `cmsg_len` is exactly 18, data little-endian."""
    var msg = Message(List[UInt8](), control_capacity=48)
    msg.set_peer(SocketAddrV4(127, 0, 0, 1, port=1))
    msg.set_ecn(1)
    msg.set_gso_segment_size(1350)  # 0x0546
    assert_equal(msg._control_appended, 48, "ECN then GSO fill 48 bytes")
    assert_equal(
        Int(_get_u64(msg._control, 24)), 18, "CMSG_LEN(2), not CMSG_SPACE(2)"
    )
    var n = 0
    for cm in msg.control():
        if n == 1:
            assert_equal(Int(cm.level), SOL_UDP)
            assert_equal(Int(cm.type), UDP_SEGMENT)
            assert_equal(len(cm.data()), 2)
            assert_equal(Int(cm.data()[0]), 0x46)
            assert_equal(Int(cm.data()[1]), 0x05)
        n += 1
    assert_equal(n, 2, "the ECN record is still first")
    for i in range(42, 48):
        assert_equal(Int(msg._control[i]), 0, "padding after the u16 is zero")

    var zero = Message(List[UInt8](), control_capacity=24)
    zero.set_gso_segment_size(0)
    assert_equal(Int(_get_u64(zero._control, 0)), 18, "0 is a legal record")
    assert_equal(zero._control_appended, 24)

    var full = Message(List[UInt8](), control_capacity=16)
    var errno = 0
    try:
        full.set_gso_segment_size(1200)
    except e:
        errno = e.errno_value()
    assert_equal(errno, EINVAL, "24 bytes do not fit in 16")
    assert_equal(full._control_appended, 0)


def test_append_control_discards_received_records() raises:
    """An append after a receive starts at offset 0 and drops the received length."""
    var msg = Message(List[UInt8](), control_capacity=48)
    _receive_one_tos_record(msg, 0xE0)
    assert_equal(msg._control_received, 24)
    var two = List[UInt8]()
    two.append(0x58)
    two.append(0x02)
    msg.append_control(Int32(SOL_UDP), Int32(UDP_SEGMENT), Span(two))
    assert_equal(msg._control_received, 0, "the peer's record is gone")
    assert_equal(msg._control_appended, 24, "the new record sits at offset 0")
    var n = 0
    for cm in msg.control():
        n += 1
        assert_equal(Int(cm.level), SOL_UDP)
        assert_equal(Int(cm.type), UDP_SEGMENT)
        assert_equal(len(cm.data()), 2)
        assert_equal(Int(cm.data()[0]), 0x58)
        assert_equal(Int(cm.data()[1]), 0x02)
    assert_equal(n, 1, "only the appended record is visible")

    # A failed append discards too: the discard precedes the capacity check.
    _receive_one_tos_record(msg, 0xE0)
    assert_equal(msg._control_received, 24)
    var big = List[UInt8](length=40, fill=1)
    var errno = 0
    try:
        msg.append_control(Int32(SOL_UDP), Int32(UDP_SEGMENT), Span(big))
    except e:
        errno = e.errno_value()
    assert_equal(errno, EINVAL)
    assert_equal(msg._control_received, 0, "discarded before the capacity check")
    assert_equal(msg._control_appended, 0)
    n = 0
    for _ in msg.control():
        n += 1
    assert_equal(n, 0, "nothing is offered and nothing walks")


def test_message_result_control_walks_only_the_received_bytes() raises:
    """`MessageResult.control()` never shows a record the caller appended,
    and `take_message` hands the message back with no received bytes."""
    var appended = Message(List[UInt8](), control_capacity=24)
    appended.set_ecn(1, family=AddrFamily.INET)
    var sent = MessageResult(0, appended^, 0)
    var n = 0
    for _ in sent.control():
        n += 1
    assert_equal(n, 0, "a send result has no kernel-written records")

    var received = Message(List[UInt8](), control_capacity=24)
    _receive_one_tos_record(received, 0xE0)
    var got = MessageResult(0, received^, 0)
    n = 0
    for _ in got.control():
        n += 1
    assert_equal(n, 1, "a receive result walks what the kernel wrote")
    var back = got^.take_message()
    assert_equal(back._control_received, 0, "reuse starts clean")
    assert_equal(back._control_appended, 0)
    n = 0
    for _ in back.control():
        n += 1
    assert_equal(n, 0)


def test_take_message_clears_the_appended_records_too() raises:
    """A message comes back from a result with an empty control area."""
    var msg = Message(List[UInt8](), control_capacity=48)
    msg.set_ecn(1, family=AddrFamily.INET)
    msg.set_gso_segment_size(600)
    assert_equal(msg._control_appended, 48)
    var r = MessageResult(1200, msg^, 0)
    var n = 0
    for _ in r.control():
        n += 1
    assert_equal(n, 0, "a send result walks nothing")
    var back = r^.take_message()
    assert_equal(
        back._control_appended, 0, "appended records are dropped on the way out"
    )
    assert_equal(back._control_received, 0)
    assert_equal(back.control_capacity(), 48, "the capacity is kept")
    n = 0
    for _ in back.control():
        n += 1
    assert_equal(n, 0)
    back.set_ecn(2, family=AddrFamily.INET)
    assert_equal(back._control_appended, 24, "the builder starts over at the front")


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


def test_peer_decoders_reject_a_short_name() raises:
    """A family byte alone is not a peer: the written name length must
    cover the whole sockaddr, else EAFNOSUPPORT."""
    var v4 = Message(List[UInt8]())
    v4.set_peer(SocketAddrV4(10, 1, 2, 3, port=53))
    v4._peer.set_len(2)  # the kernel wrote only the family
    var r4 = MessageResult(0, v4^, 0)
    assert_true(r4.peer_family() == AddrFamily.INET, "the family still reads")
    var short = False
    try:
        _ = r4.peer_v4()
    except e:
        short = e.errno_value() == EAFNOSUPPORT
    assert_true(short, "2 bytes of AF_INET name: EAFNOSUPPORT, not stale bytes")

    var v6 = Message(List[UInt8]())
    v6.set_peer(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=9))
    v6._peer.set_len(16)  # a sockaddr_in worth of an AF_INET6 name
    var r6 = MessageResult(0, v6^, 0)
    assert_true(r6.peer_family() == AddrFamily.INET6)
    short = False
    try:
        _ = r6.peer_v6()
    except e:
        short = e.errno_value() == EAFNOSUPPORT
    assert_true(short, "16 bytes of AF_INET6 name: EAFNOSUPPORT")


def test_message_result_transferred_clamps_count_above_payload_length() raises:
    """A kernel-reported count past the payload (MSG_TRUNC) must not abort
    transferred(); it clamps to the payload's own length instead."""
    var msg = Message(List[UInt8](length=2, fill=0x41))
    var r = MessageResult(10, msg^, Int32(MSG_TRUNC))
    assert_equal(r.count, 10, "the raw kernel count is preserved")
    assert_equal(len(r.transferred()), 2, "transferred() clamps to the payload")


def main() raises:
    test_walker_yields_each_record()
    test_walker_stops_at_a_record_past_the_end()
    test_walker_stops_before_a_wrapping_record_length()
    test_next_past_the_end_yields_an_empty_record()
    test_ecn_takes_the_first_tos_record()
    test_ecn_skips_a_leading_non_tos_record()
    test_gro_segment_size_reads_the_udp_gro_record()
    test_message_owns_payload_and_starts_without_peer()
    test_negative_control_capacity_clamps_to_zero()
    test_control_space_is_cmsg_space()
    test_set_peer_records_the_family()
    test_payload_mutates_in_place()
    test_set_control_received_clamps_to_capacity()
    test_set_ecn_derives_the_record_from_the_peer()
    test_set_ecn_treats_a_mapped_peer_as_v4()
    test_set_ecn_with_explicit_family_and_no_peer()
    test_set_ecn_explicit_family_and_masking_stacks()
    test_a_send_offers_only_the_appended_records()
    test_append_control_walks_back_in_order()
    test_append_control_overflow_is_einval_and_writes_nothing()
    test_append_control_discards_received_records()
    test_set_gso_segment_size_appends_an_18_byte_record()
    test_message_result_control_walks_only_the_received_bytes()
    test_take_message_clears_the_appended_records_too()
    test_set_ecn_raises_einval_without_family_or_room()
    test_message_result_exposes_count_peer_and_flags()
    test_message_result_v4_peer_and_ctrunc()
    test_peer_decoders_reject_a_short_name()
    test_message_result_transferred_clamps_count_above_payload_length()
    print("PASS: test_message.mojo")
