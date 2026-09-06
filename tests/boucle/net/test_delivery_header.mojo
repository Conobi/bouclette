"""DeliveryHeader: the 16-byte io_uring_recvmsg_out prefix of a multishot
recvmsg delivery, decoded from hand-built buffers.

Covers the golden byte layout, capacity-based region offsets, truncated
control and payload regions, a name written longer than its capacity,
capacities whose sum overruns the buffer, a buffer shorter than the
header (refused by `parse`, decoded as all-zero by the constructor).
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.error import IOError
from boucle.net.message import (
    DELIVERY_HEADER_LEN,
    DeliveryHeader,
    write_delivery_header,
)
from boucle.socle.platform import EINVAL, MSG_CTRUNC, MSG_TRUNC

comptime NAME_CAP = 28
comptime CTRL_CAP = 16
# One IP_TOS record needs cmsg_len 17 (a 16-byte cmsghdr plus one data
# byte); CTRL_CAP (16) is deliberately one byte short of that so the
# truncation test below can prove a too-small capacity clamps the walker
# to nothing. A test that expects the record to actually be found needs
# a capacity that can hold it: `_cmsg_align(17) == 24`.
comptime FULL_CTRL_CAP = 24
comptime SOL_IP = 0
comptime IP_TOS = 1


def _put_u32(mut buf: List[UInt8], offset: Int, value: UInt32):
    """Store `value` little-endian at `offset` in `buf`.

    Args:
        buf: The buffer to write into.
        offset: Byte offset of the first byte.
        value: The 32-bit value to store.
    """
    for i in range(4):
        buf[offset + i] = UInt8((value >> UInt32(8 * i)) & UInt32(0xFF))


def _build(
    *, namelen: Int, controllen: Int, payloadlen: Int, flags: Int, total: Int
) -> List[UInt8]:
    """Build a zeroed delivery buffer with the four header fields set.

    Args:
        namelen: Value of the namelen field.
        controllen: Value of the controllen field.
        payloadlen: Value of the payloadlen field.
        flags: Value of the flags field.
        total: Total buffer length in bytes.

    Returns:
        The buffer.
    """
    var buf = List[UInt8](length=total, fill=0)
    _put_u32(buf, 0, UInt32(namelen))
    _put_u32(buf, 4, UInt32(controllen))
    _put_u32(buf, 8, UInt32(payloadlen))
    _put_u32(buf, 12, UInt32(flags))
    return buf^


def _write_tos_cmsg(mut buf: List[UInt8], offset: Int, tos: UInt8):
    """Write a SOL_IP/IP_TOS control record (cmsg_len 17) at `offset`.

    Args:
        buf: The buffer holding the control area.
        offset: Byte offset of the record's cmsghdr.
        tos: The one-byte TOS payload.
    """
    _put_u32(buf, offset, UInt32(17))       # cmsg_len low word (size_t)
    _put_u32(buf, offset + 4, UInt32(0))    # cmsg_len high word
    _put_u32(buf, offset + 8, UInt32(SOL_IP))
    _put_u32(buf, offset + 12, UInt32(IP_TOS))
    buf[offset + 16] = tos


def test_golden_layout() raises:
    """The encoder writes four little-endian UInt32 at offsets 0, 4, 8, 12."""
    assert_equal(DELIVERY_HEADER_LEN, 16)
    var buf = List[UInt8](length=16, fill=0)
    var base = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    write_delivery_header(
        base,
        namelen=UInt32(0x01020304),
        controllen=UInt32(0x05060708),
        payloadlen=UInt32(0x090A0B0C),
        flags=UInt32(0x0D0E0F10),
    )
    assert_equal(Int(buf[0]), 0x04)
    assert_equal(Int(buf[3]), 0x01)
    assert_equal(Int(buf[4]), 0x08)
    assert_equal(Int(buf[7]), 0x05)
    assert_equal(Int(buf[8]), 0x0C)
    assert_equal(Int(buf[11]), 0x09)
    assert_equal(Int(buf[12]), 0x10)
    assert_equal(Int(buf[15]), 0x0D)
    var hdr = DeliveryHeader.parse(
        Span(buf), name_capacity=0, control_capacity=0
    )
    assert_equal(Int(hdr.namelen()), 0x01020304)
    assert_equal(Int(hdr.controllen()), 0x05060708)
    assert_equal(Int(hdr.payloadlen()), 0x090A0B0C)
    assert_equal(Int(hdr.flags()), 0x0D0E0F10)


def test_regions_follow_capacities_not_written_lengths() raises:
    """An IPv4 name (16 bytes) in a 28-byte slot leaves the payload at 16+28+24."""
    var buf = _build(namelen=16, controllen=17, payloadlen=5, flags=0, total=128)
    buf[16] = UInt8(2)                       # AF_INET low byte in the name
    _write_tos_cmsg(buf, 16 + NAME_CAP, UInt8(0x02))
    var payload_at = 16 + NAME_CAP + FULL_CTRL_CAP
    for i in range(5):
        buf[payload_at + i] = UInt8(ord("a") + i)

    var hdr = DeliveryHeader.parse(
        Span(buf), name_capacity=NAME_CAP, control_capacity=FULL_CTRL_CAP
    )
    var name = hdr.name()
    assert_equal(len(name), 16)
    assert_equal(Int(name[0]), 2)
    var payload = hdr.payload()
    assert_equal(len(payload), 5)
    assert_equal(Int(payload[0]), ord("a"))
    assert_equal(Int(payload[4]), ord("e"))
    var ecn = hdr.control().ecn()
    assert_true(ecn, "the TOS record must be found in the control region")
    assert_equal(Int(ecn.value()), 2)
    assert_true(not (hdr.flags() & UInt32(MSG_TRUNC)))


def test_truncated_control_and_payload_are_clamped() raises:
    """`controllen` and `payloadlen` above capacity clamp to what the buffer holds."""
    var buf = _build(
        namelen=16,
        controllen=40,
        payloadlen=500,
        flags=MSG_TRUNC | MSG_CTRUNC,
        total=16 + NAME_CAP + CTRL_CAP + 8,
    )
    # A 17-byte record does not fit a 16-byte capacity: if control() clamps
    # to the capacity the walker yields nothing; if it used controllen (40)
    # it would read the record and the assertion below would fail.
    _write_tos_cmsg(buf, 16 + NAME_CAP, UInt8(0x01))
    var hdr = DeliveryHeader.parse(
        Span(buf), name_capacity=NAME_CAP, control_capacity=CTRL_CAP
    )
    assert_true(not hdr.control().ecn(), "clamped control area holds no record")
    assert_equal(len(hdr.payload()), 8)
    assert_true((hdr.flags() & UInt32(MSG_TRUNC)) != 0)
    assert_true((hdr.flags() & UInt32(MSG_CTRUNC)) != 0)


def test_name_longer_than_capacity_is_clamped() raises:
    """`namelen` above the slot returns exactly `name_capacity` bytes."""
    var buf = _build(namelen=64, controllen=0, payloadlen=0, flags=0, total=64)
    var hdr = DeliveryHeader.parse(
        Span(buf), name_capacity=NAME_CAP, control_capacity=0
    )
    assert_equal(len(hdr.name()), NAME_CAP)
    assert_equal(len(hdr.payload()), 0)


def test_capacities_beyond_buffer_clamp_to_empty() raises:
    """Capacities whose sum overruns the buffer clamp every region, not just one."""
    # 16 (header) + 28 (name) + 64 (control) = 108, well past the 40-byte buffer.
    var buf = _build(namelen=28, controllen=64, payloadlen=64, flags=0, total=40)
    var hdr = DeliveryHeader.parse(
        Span(buf), name_capacity=28, control_capacity=64
    )
    var name = hdr.name()
    assert_equal(
        len(name),
        40 - DELIVERY_HEADER_LEN,
        "name clamps to what remains of the buffer, not the full capacity",
    )
    assert_true(
        not hdr.control().ecn(),
        "control's region is empty past the buffer end: nothing to walk",
    )
    assert_equal(len(hdr.payload()), 0, "payload's region is also empty")


def test_short_buffer_raises_einval() raises:
    """Fewer than 16 bytes cannot hold a header."""
    var buf = List[UInt8](length=8, fill=0)
    var raised = False
    try:
        _ = DeliveryHeader.parse(
            Span(buf), name_capacity=NAME_CAP, control_capacity=0
        )
    except e:
        raised = e == IOError(positive_errno=EINVAL)
    assert_true(raised, "parse must raise EINVAL on a short buffer")


def test_short_buffer_constructor_reads_zero() raises:
    """The unchecked constructor over fewer than 16 bytes reads every field as zero.

    A `Datagram` over a lease that names no buffer views an empty span;
    every accessor must degrade to zero and empty rather than index past
    the end.
    """
    var buf = List[UInt8](length=8, fill=0)
    var hdr = DeliveryHeader(Span(buf), NAME_CAP, 0)
    assert_equal(Int(hdr.flags()), 0)
    assert_equal(Int(hdr.namelen()), 0)
    assert_equal(Int(hdr.controllen()), 0)
    assert_equal(Int(hdr.payloadlen()), 0)
    assert_equal(len(hdr.name()), 0, "no name region")
    assert_equal(len(hdr.payload()), 0, "no payload region")
    var records = 0
    for _ in hdr.control():
        records += 1
    assert_equal(records, 0, "the control walker yields nothing")
    assert_true(not hdr.control().ecn())

    # The two fields that do fit in eight bytes may hold anything: the
    # regions they describe lie past the buffer and still clamp to empty.
    var noisy = List[UInt8](length=8, fill=UInt8(0xFF))
    var garbage = DeliveryHeader(Span(noisy), NAME_CAP, FULL_CTRL_CAP)
    assert_equal(Int(garbage.payloadlen()), 0, "past the buffer: zero")
    assert_equal(Int(garbage.flags()), 0)
    assert_equal(len(garbage.name()), 0, "a huge namelen names no bytes")
    assert_equal(len(garbage.payload()), 0)
    assert_true(not garbage.control().ecn())


def main() raises:
    test_golden_layout()
    test_regions_follow_capacities_not_written_lengths()
    test_truncated_control_and_payload_are_clamped()
    test_name_longer_than_capacity_is_clamped()
    test_capacities_beyond_buffer_clamp_to_empty()
    test_short_buffer_raises_einval()
    test_short_buffer_constructor_reads_zero()
    print("PASS: test_delivery_header.mojo")
