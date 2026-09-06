"""Property checks over the pure decoders of the datagram path.

The cmsg walker, `ecn()`, `DeliveryHeader`, the sockaddr length clamp,
the family decoder, `_next_pow2`, the completion flag decoders and the
`transferred()` clamp all parse bytes or numbers that come from the
kernel or from a peer. A hand-picked example pins one shape; these
checks throw a few thousand pseudo-random inputs, within and just
outside the valid ranges, at each of them and assert the invariant
that matters: nothing is read outside the span, every length is
clamped, and every walk terminates.

The generator is a deterministic xorshift64 seeded from a constant, so
a failure reproduces; the seed is printed when any property fails.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.drivers.bufring import _next_pow2
from boucle.error import IOError
from boucle.net.addr import SocketAddrStorAny, SocketAddrV6
from boucle.net.message import (
    _cmsg_align,
    ControlMessages,
    DELIVERY_HEADER_LEN,
    DeliveryHeader,
    Message,
    MessageResult,
    write_delivery_header,
)
from boucle.net.options import AddrFamily
from boucle.proactor.completion import buffer_id, has_more
from boucle.socle.platform import (
    EINVAL,
    IORING_CQE_BUFFER_SHIFT,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    IP_TOS,
    IPV6_TCLASS,
    SOL_IP,
    SOL_IPV6,
    socklen_t,
)
from boucle.watch.transfer import TransferResult

comptime SEED: UInt64 = 0x9E3779B97F4A7C15
comptime ITERATIONS = 5000
comptime CMSG_HDR = 16
comptime SOCKADDR_MAX = 28


# ===----------------------------------------------------------------------=== #
# Generator
# ===----------------------------------------------------------------------=== #


struct Xorshift64(Movable):
    """A xorshift64 generator: tiny, deterministic and good enough for fuzzing.

    Fields:
        state: The 64-bit state; never zero.
    """

    var state: UInt64

    def __init__(out self, seed: UInt64):
        """Seed the generator.

        Args:
            seed: Any value; zero is replaced so the sequence never sticks.
        """
        self.state = seed if seed != 0 else UInt64(1)

    def next(mut self) -> UInt64:
        """Return the next 64-bit value.

        Returns:
            A pseudo-random UInt64.
        """
        var x = self.state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        self.state = x
        return x

    def below(mut self, n: Int) -> Int:
        """Return a value in `0 ..< n`.

        Args:
            n: The exclusive upper bound, at least 1.

        Returns:
            A pseudo-random Int in `[0, n)`.
        """
        return Int(self.next() % UInt64(n))

    def between(mut self, lo: Int, hi: Int) -> Int:
        """Return a value in `lo ... hi`, both included.

        Args:
            lo: The inclusive lower bound.
            hi: The inclusive upper bound, at least `lo`.

        Returns:
            A pseudo-random Int in `[lo, hi]`.
        """
        return lo + self.below(hi - lo + 1)

    def chance(mut self, one_in: Int) -> Bool:
        """Return True about once every `one_in` calls.

        Args:
            one_in: The denominator of the probability.

        Returns:
            True with probability `1 / one_in`.
        """
        return self.below(one_in) == 0

    def fill(mut self, mut buf: List[UInt8]):
        """Overwrite every byte of `buf` with a random value.

        Args:
            buf: The buffer to fill.
        """
        for i in range(len(buf)):
            buf[i] = UInt8(self.next() & 0xFF)

    def bytes(mut self, n: Int) -> List[UInt8]:
        """Return `n` random bytes.

        Args:
            n: The length of the buffer.

        Returns:
            A fresh buffer of random bytes.
        """
        var buf = List[UInt8](length=n, fill=0)
        self.fill(buf)
        return buf^


# ===----------------------------------------------------------------------=== #
# Byte helpers
# ===----------------------------------------------------------------------=== #


def _put_u64(mut buf: List[UInt8], at: Int, value: UInt64):
    """Store a little-endian UInt64 at byte offset `at`.

    Args:
        buf: The byte buffer; must hold `at + 8` bytes.
        at: The offset of the first byte.
        value: The value to store.
    """
    buf.unsafe_ptr().unsafe_offset(at).unsafe_bitcast[UInt64]().unsafe_store[
        alignment=1
    ](value)


def _put_i32(mut buf: List[UInt8], at: Int, value: Int32):
    """Store a little-endian Int32 at byte offset `at`.

    Args:
        buf: The byte buffer; must hold `at + 4` bytes.
        at: The offset of the first byte.
        value: The value to store.
    """
    buf.unsafe_ptr().unsafe_offset(at).unsafe_bitcast[Int32]().unsafe_store[
        alignment=1
    ](value)


def _get_u32(buf: List[UInt8], at: Int) -> UInt32:
    """Read the little-endian UInt32 at byte offset `at`.

    Args:
        buf: The byte buffer; must hold `at + 4` bytes.
        at: The offset of the first byte.

    Returns:
        The decoded value.
    """
    return (
        UInt32(buf[at])
        | (UInt32(buf[at + 1]) << 8)
        | (UInt32(buf[at + 2]) << 16)
        | (UInt32(buf[at + 3]) << 24)
    )


def _within(inner: Span[UInt8, _], base: Int, total: Int) -> Bool:
    """Return True when `inner` addresses only bytes of `[base, base + total)`.

    The outer buffer is named by address and length rather than by a
    second span so the two views of one buffer never alias in the call.
    An empty span counts as inside when its start lies in the buffer or
    at its end, which is where the walker parks an exhausted cursor.

    Args:
        inner: The span under test.
        base: The address of the buffer's first byte.
        total: The buffer's length.

    Returns:
        True if every byte of `inner` is a byte of the buffer.
    """
    var start = Int(inner.unsafe_ptr())
    return start >= base and start + len(inner) <= base + total


def _write_record(
    mut buf: List[UInt8], at: Int, cmsg_len: UInt64, level: Int32, type: Int32
):
    """Write a cmsghdr at `at`; the data bytes after it are left as they are.

    Args:
        buf: The control area; must hold `at + 16` bytes.
        at: The offset of the record.
        cmsg_len: The `cmsg_len` field, taken verbatim.
        level: The `cmsg_level` field.
        type: The `cmsg_type` field.
    """
    _put_u64(buf, at, cmsg_len)
    _put_i32(buf, at + 8, level)
    _put_i32(buf, at + 12, type)


# ===----------------------------------------------------------------------=== #
# 1. The cmsg walker
# ===----------------------------------------------------------------------=== #


def _check_walk(buf: List[UInt8]) raises:
    """Walk `buf` once and check every bound the walker promises.

    The walk ends within `len // 16 + 1` steps, every record's data lies
    inside the span, and once exhausted `__next__` returns an empty
    record without moving.

    Args:
        buf: The control area to walk.
    """
    var base = Int(buf.unsafe_ptr())
    var walker = ControlMessages(Span(buf))
    var limit = len(buf) // CMSG_HDR + 1
    var steps = 0
    while walker.__has_next__():
        steps += 1
        assert_true(
            steps <= limit,
            "walk of " + String(len(buf)) + " bytes did not end in "
            + String(limit) + " steps",
        )
        var before = walker._offset
        var cm = walker.__next__()
        assert_true(
            _within(cm.data(), base, len(buf)), "record data outside the span"
        )
        assert_true(
            walker._offset > before, "the cursor must advance on every record"
        )
        assert_true(
            walker._offset % 8 == 0, "the cursor must stay 8-byte aligned"
        )
    var first = walker.__next__()
    assert_equal(len(first.data()), 0, "an exhausted walker yields no data")
    assert_equal(Int(first.level), 0)
    assert_equal(Int(first.type), 0)
    assert_equal(walker._offset, len(buf), "exhaustion parks at the end")
    var second = walker.__next__()
    assert_equal(len(second.data()), 0)
    assert_equal(walker._offset, len(buf), "a parked cursor never moves")
    assert_true(_within(first.data(), base, len(buf)))
    assert_true(_within(second.data(), base, len(buf)))


def property_cmsg_walker_stays_in_bounds_and_terminates(
    mut rng: Xorshift64,
) raises:
    """For any control area, walking never reads past it and always ends.

    Random bytes of length 0..200, then the same with a hostile
    `cmsg_len` (0, 1..15, exactly the remaining bytes and one to either
    side, 2^31, 2^63, 2^64-1) written at a random offset, in both the
    aligned and the unaligned positions.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var n = rng.between(0, 200)
        var buf = rng.bytes(n)
        _check_walk(buf)
        if n < CMSG_HDR:
            continue
        var at = rng.between(0, n - CMSG_HDR)
        if rng.chance(2):
            at = at & ~7
        var remaining = UInt64(n - at)
        var hostile: UInt64
        var pick = rng.below(9)
        if pick == 0:
            hostile = 0
        elif pick == 1:
            hostile = UInt64(rng.between(1, 15))
        elif pick == 2:
            hostile = remaining - 1
        elif pick == 3:
            hostile = remaining
        elif pick == 4:
            hostile = remaining + 1
        elif pick == 5:
            hostile = UInt64(1) << 31
        elif pick == 6:
            hostile = UInt64(1) << 63
        elif pick == 7:
            hostile = UInt64.MAX
        else:
            hostile = UInt64(rng.between(CMSG_HDR, n))
        _put_u64(buf, at, hostile)
        _check_walk(buf)
        # A chain of well-formed records ending on the hostile one.
        var chain = List[UInt8](length=n, fill=0)
        var pos = 0
        while pos + CMSG_HDR <= n:
            var data = rng.between(0, 8)
            var record = UInt64(CMSG_HDR + data)
            if pos + _cmsg_align(CMSG_HDR + data) > n or rng.chance(4):
                _write_record(chain, pos, hostile, 0, 0)
                break
            _write_record(chain, pos, record, 0, 0)
            pos += _cmsg_align(CMSG_HDR + data)
        _check_walk(chain)


def property_cmsg_align_rounds_up_to_eight(mut rng: Xorshift64) raises:
    """`_cmsg_align(x)` is a multiple of 8, at least `x`, and below `x + 8`.

    Checked for random `x` in `0 ..= Int.MAX - 7` and at the edges of
    that range, so the arithmetic is shown to hold on every value the
    walker can pass it, not only on lengths a kernel would write. Above
    `Int.MAX - 7` no multiple of 8 at or above `x` exists in a 64-bit
    Int, so the invariant cannot be stated there; the walker never gets
    there either, since it bounds `cmsg_len` by the span length before
    rounding.

    Args:
        rng: The generator.
    """
    def check(x: Int) raises:
        """Assert the three rounding facts for one value.

        Args:
            x: The value to round.
        """
        var a = _cmsg_align(x)
        assert_equal(a % 8, 0, "not a multiple of 8 for " + String(x))
        assert_true(a >= x, "rounded below the input for " + String(x))
        assert_true(a - x < 8, "rounded too far for " + String(x))

    for _ in range(ITERATIONS):
        var pick = rng.below(4)
        if pick == 0:
            check(rng.between(0, 64))
        elif pick == 1:
            check(rng.between(0, 1 << 20))
        elif pick == 2:
            check(min(Int(rng.next() >> 1), Int.MAX - 7))
        else:
            check(Int(rng.next() >> UInt64(rng.between(1, 63))))
    for k in range(64):
        check(k)
    check(Int.MAX - 8)
    check(Int.MAX - 7)


# ===----------------------------------------------------------------------=== #
# 2. ecn()
# ===----------------------------------------------------------------------=== #


def _is_tos_record(level: Int32, type: Int32) -> Bool:
    """Return True for the two level/type pairs `ecn()` reads.

    Args:
        level: A `cmsg_level`.
        type: A `cmsg_type`.

    Returns:
        True for SOL_IP/IP_TOS and SOL_IPV6/IPV6_TCLASS.
    """
    return (level == Int32(SOL_IP) and type == Int32(IP_TOS)) or (
        level == Int32(SOL_IPV6) and type == Int32(IPV6_TCLASS)
    )


def property_ecn_reads_the_low_two_bits(mut rng: Xorshift64) raises:
    """`ecn()` is `tos & 3` from the first TOS/TCLASS record, else None.

    A one-byte IP_TOS record or a four-byte IPV6_TCLASS record decodes
    to its low two bits, also when a record of another level/type comes
    first; a TOS/TCLASS record with too little data, or a record of any
    other level/type, decodes to None.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var buf = rng.bytes(48)
        var v6 = rng.chance(2)
        var lead = rng.chance(2)
        var at = 24 if lead else 0
        if lead:
            var level = Int32(rng.next() & 0xFFFFFFFF)
            var type = Int32(rng.next() & 0xFFFFFFFF)
            while _is_tos_record(level, type):
                type += 1
            # 17..24 bytes pad to 24, so the TOS record sits at offset 24.
            _write_record(buf, 0, UInt64(rng.between(17, 24)), level, type)
        var tos = UInt8(rng.next() & 0xFF)
        if v6:
            _write_record(buf, at, 20, Int32(SOL_IPV6), Int32(IPV6_TCLASS))
        else:
            _write_record(buf, at, 17, Int32(SOL_IP), Int32(IP_TOS))
        buf[at + CMSG_HDR] = tos
        var walk = ControlMessages(Span(buf)[: at + 24])
        var got = walk.ecn()
        assert_true(got, "a TOS record must decode")
        assert_equal(Int(got.value()), Int(tos & 0x03))

        # Too short: no data byte for TOS, fewer than four for TCLASS.
        var short = rng.bytes(24)
        if v6:
            _write_record(
                short,
                0,
                UInt64(rng.between(16, 19)),
                Int32(SOL_IPV6),
                Int32(IPV6_TCLASS),
            )
        else:
            _write_record(short, 0, 16, Int32(SOL_IP), Int32(IP_TOS))
        assert_true(
            not ControlMessages(Span(short)).ecn(),
            "a record too short for its codepoint decodes to None",
        )

        # Any other level/type, with plenty of data, is not a codepoint.
        var other = rng.bytes(24)
        var level = Int32(rng.next() & 0xFFFFFFFF)
        var type = Int32(rng.next() & 0xFFFFFFFF)
        if rng.chance(3):
            level = Int32(SOL_IP) if rng.chance(2) else Int32(SOL_IPV6)
        if rng.chance(3):
            type = Int32(IP_TOS) if rng.chance(2) else Int32(IPV6_TCLASS)
        if _is_tos_record(level, type):
            continue
        _write_record(other, 0, UInt64(rng.between(20, 24)), level, type)
        assert_true(
            not ControlMessages(Span(other)).ecn(),
            "level " + String(level) + " type " + String(type)
            + " is not a codepoint",
        )


# ===----------------------------------------------------------------------=== #
# 3. DeliveryHeader
# ===----------------------------------------------------------------------=== #


def _clamped_len(start: Int, wanted: Int, total: Int) -> Int:
    """Return how many bytes a region at `start` can yield from `total`.

    Args:
        start: The region's first byte.
        wanted: The length asked for.
        total: The buffer length.

    Returns:
        `min(wanted, total - start)` floored at zero.
    """
    return max(min(wanted, max(total - start, 0)), 0)


def property_delivery_header_roundtrips_and_clamps(
    mut rng: Xorshift64,
) raises:
    """Every header field reads back and every region stays in the buffer.

    For random fields over the full UInt32 range, a buffer of 16..512
    bytes and random capacities, `parse` succeeds, each accessor returns
    what was written, `name()` is `min(namelen, name_capacity)` clamped
    to the room after the header, `control()` likewise after the name
    slot, `payload()` is `payloadlen` clamped to the room after both
    slots, and each span lies within the buffer.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var total = rng.between(16, 512)
        var name_cap = rng.between(0, 64)
        var ctrl_cap = rng.between(0, 128)
        var buf = rng.bytes(total)
        var namelen = UInt32(rng.next() & 0xFFFFFFFF)
        var controllen = UInt32(rng.next() & 0xFFFFFFFF)
        var payloadlen = UInt32(rng.next() & 0xFFFFFFFF)
        var flags = UInt32(rng.next() & 0xFFFFFFFF)
        if rng.chance(2):
            namelen = UInt32(rng.between(0, 80))
            controllen = UInt32(rng.between(0, 160))
            payloadlen = UInt32(rng.between(0, 600))
        var base = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(buf.unsafe_ptr())
        )
        write_delivery_header(
            base,
            namelen=namelen,
            controllen=controllen,
            payloadlen=payloadlen,
            flags=flags,
        )
        var origin = Int(buf.unsafe_ptr())
        var hdr = DeliveryHeader.parse(
            Span(buf), name_capacity=name_cap, control_capacity=ctrl_cap
        )
        assert_equal(Int(hdr.namelen()), Int(namelen))
        assert_equal(Int(hdr.controllen()), Int(controllen))
        assert_equal(Int(hdr.payloadlen()), Int(payloadlen))
        assert_equal(Int(hdr.flags()), Int(flags))

        var name = hdr.name()
        var name_at = DELIVERY_HEADER_LEN
        assert_equal(
            len(name),
            _clamped_len(name_at, min(Int(namelen), name_cap), total),
            "name length",
        )
        assert_true(_within(name, origin, total), "name outside the buffer")
        if len(name) > 0:
            assert_equal(Int(name.unsafe_ptr()) - origin, name_at)

        var ctrl = hdr.control()._bytes
        var ctrl_at = name_at + name_cap
        assert_equal(
            len(ctrl),
            _clamped_len(ctrl_at, min(Int(controllen), ctrl_cap), total),
            "control length",
        )
        assert_true(_within(ctrl, origin, total), "control outside the buffer")
        if len(ctrl) > 0:
            assert_equal(Int(ctrl.unsafe_ptr()) - origin, ctrl_at)
        _check_walk(List[UInt8](ctrl))

        var payload = hdr.payload()
        var payload_at = ctrl_at + ctrl_cap
        assert_equal(
            len(payload),
            _clamped_len(payload_at, Int(payloadlen), total),
            "payload length",
        )
        assert_true(_within(payload, origin, total), "payload outside the buffer")
        if len(payload) > 0:
            assert_equal(Int(payload.unsafe_ptr()) - origin, payload_at)


def property_delivery_region_clamps_both_ends(mut rng: Xorshift64) raises:
    """`_region(start, length)` never leaves the buffer for any arguments.

    A negative or out-of-range `start` clamps to the buffer's bounds, a
    negative `length` yields nothing, and the result is exactly the
    bytes `[start, start + length)` intersected with the buffer. The
    pinned case is `_region(1, Int.MAX)` over a one-byte buffer, where
    `start + length` wraps unless `length` is clamped before the add;
    the public accessors never pass such a length (`payloadlen` is a
    UInt32), so only a direct caller can reach it.

    Args:
        rng: The generator.
    """
    var one = List[UInt8](length=1, fill=0)
    var probe = DeliveryHeader(Span(one), 0, 0)
    assert_equal(len(probe._region(1, Int.MAX)), 0, "start + length wrapped")
    for _ in range(ITERATIONS):
        var total = rng.between(0, 128)
        var buf = rng.bytes(total)
        var origin = Int(buf.unsafe_ptr())
        var hdr = DeliveryHeader(Span(buf), 0, 0)
        var start = rng.between(-300, 300)
        var length = rng.between(-300, 300)
        if rng.chance(8):
            start = Int.MIN if rng.chance(2) else Int.MAX
        if rng.chance(8):
            length = Int.MIN if rng.chance(2) else Int.MAX
        var region = hdr._region(start, length)
        assert_true(_within(region, origin, total), "region outside the buffer")
        var lo = max(min(start, total), 0)
        var expect = min(max(length, 0), total - lo)
        assert_equal(len(region), expect, "region length")
        if len(region) > 0:
            assert_equal(Int(region.unsafe_ptr()) - origin, lo)


def property_short_delivery_buffer_reads_zero(mut rng: Xorshift64) raises:
    """A buffer under 16 bytes is refused by `parse` and harmless unchecked.

    `parse` raises EINVAL. The unchecked constructor reads a field as 0
    when its four bytes do not fit (as the bytes otherwise) and every
    region is empty, whatever the capacities.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var total = rng.between(0, 15)
        var buf = rng.bytes(total)
        var name_cap = rng.between(0, 64)
        var ctrl_cap = rng.between(0, 128)
        var raised = False
        try:
            _ = DeliveryHeader.parse(
                Span(buf), name_capacity=name_cap, control_capacity=ctrl_cap
            )
        except e:
            raised = e == IOError(positive_errno=EINVAL)
        assert_true(raised, "parse must raise EINVAL on " + String(total) + " bytes")

        var hdr = DeliveryHeader(Span(buf), name_cap, ctrl_cap)
        var fields = List[UInt32]()
        fields.append(hdr.namelen())
        fields.append(hdr.controllen())
        fields.append(hdr.payloadlen())
        fields.append(hdr.flags())
        for i in range(4):
            var at = 4 * i
            var expect = _get_u32(buf, at) if at + 4 <= total else UInt32(0)
            assert_equal(Int(fields[i]), Int(expect), "field " + String(i))
        assert_equal(len(hdr.name()), 0, "no name region")
        assert_equal(len(hdr.control()._bytes), 0, "no control region")
        assert_equal(len(hdr.payload()), 0, "no payload region")
        assert_true(not hdr.control().ecn())


# ===----------------------------------------------------------------------=== #
# 4. sockaddr storage and family
# ===----------------------------------------------------------------------=== #


def property_addr_len_is_clamped_to_the_slot(mut rng: Xorshift64) raises:
    """`set_len(n)` records `min(n, 28)` and `addr_len()` never exceeds 28.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var raw = UInt32(rng.next() & 0xFFFFFFFF)
        if rng.chance(2):
            raw = UInt32(rng.between(0, 40))
        var stor = SocketAddrStorAny()
        stor.set_len(socklen_t(raw))
        var expect = min(Int(raw), SOCKADDR_MAX)
        assert_equal(Int(stor.addr_len()), expect)
        assert_true(Int(stor.addr_len()) <= SOCKADDR_MAX)
        # The raw field, written by the kernel behind the clamp, must
        # still read back clamped.
        stor.len = socklen_t(raw)
        assert_equal(Int(stor.addr_len()), expect)
        assert_true(Int(stor.family().id) <= 16, "family from a zero slot")


def property_family_decodes_only_known_ids(mut rng: Xorshift64) raises:
    """`from_sockaddr` is UNSPEC under two bytes and only ever a known family.

    For random bytes of length 0..40, the result is UNSPEC when fewer
    than two bytes are present; otherwise it is INET, INET6 or UNIX
    exactly when the first two bytes spell that id, and UNSPEC for
    every other id.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var n = rng.between(0, 40)
        var buf = rng.bytes(n)
        if n >= 2 and rng.chance(2):
            var pick = rng.below(5)
            var id: UInt16
            if pick == 0:
                id = AddrFamily.INET.id
            elif pick == 1:
                id = AddrFamily.INET6.id
            elif pick == 2:
                id = AddrFamily.UNIX.id
            elif pick == 3:
                id = AddrFamily.NETLINK.id
            else:
                id = UInt16(rng.between(0, 20))
            buf[0] = UInt8(id & 0xFF)
            buf[1] = UInt8(id >> 8)
        var fam = AddrFamily.from_sockaddr(Span(buf))
        if n < 2:
            assert_true(fam == AddrFamily.UNSPEC, "under two bytes: UNSPEC")
            continue
        var id = UInt16(buf[0]) | (UInt16(buf[1]) << 8)
        if id == AddrFamily.INET.id:
            assert_true(fam == AddrFamily.INET)
        elif id == AddrFamily.INET6.id:
            assert_true(fam == AddrFamily.INET6)
        elif id == AddrFamily.UNIX.id:
            assert_true(fam == AddrFamily.UNIX)
        else:
            assert_true(
                fam == AddrFamily.UNSPEC, "id " + String(id) + " must be UNSPEC"
            )


def property_ipv4_mapped_is_exactly_the_ffff_prefix(
    mut rng: Xorshift64,
) raises:
    """`is_ipv4_mapped` is true iff the address is `::ffff:a.b.c.d`.

    Half the inputs get the exact prefix; the rest get random segments,
    including ones that differ from the prefix in a single segment.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var segs = InlineArray[UInt16, 8](fill=0)
        for i in range(8):
            segs[i] = UInt16(rng.next() & 0xFFFF)
        var mapped = rng.chance(2)
        if mapped:
            for i in range(5):
                segs[i] = 0
            segs[5] = 0xFFFF
        elif rng.chance(2):
            for i in range(5):
                segs[i] = 0
            segs[5] = 0xFFFF
            var flip = rng.below(6)
            segs[flip] = segs[flip] ^ UInt16(1 << rng.below(16))
        var addr = SocketAddrV6(
            segs[0], segs[1], segs[2], segs[3],
            segs[4], segs[5], segs[6], segs[7],
            port=UInt16(rng.next() & 0xFFFF),
            scope_id=UInt32(rng.next() & 0xFFFFFFFF),
        )
        var expect = (
            segs[0] == 0
            and segs[1] == 0
            and segs[2] == 0
            and segs[3] == 0
            and segs[4] == 0
            and segs[5] == 0xFFFF
        )
        assert_equal(addr.is_ipv4_mapped(), expect)


def property_v6_storage_round_trip_keeps_the_address(
    mut rng: Xorshift64,
) raises:
    """`addr_stor().to_v6()` returns the segments, port and scope it was given.

    `SocketAddrStorV6.to_v6` must read all four address words as
    fields; reading `sin6_addr_b/c/d` through a pointer offset from
    `sin6_addr_a` returned zeros for them. The pinned case is the
    mapped address `::ffff:192.168.1.1` keeping its `is_ipv4_mapped`
    answer across the round trip: `Message.set_ecn` relies on that
    chain to pick IP_TOS for a mapped peer, and `MessageResult.peer_v6`
    goes through `to_v6` too.

    Args:
        rng: The generator.
    """
    var mapped = SocketAddrV6(0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101, port=0)
    assert_true(
        mapped.addr_stor().to_v6().is_ipv4_mapped(),
        "a mapped address must stay mapped across the storage round trip",
    )
    for _ in range(ITERATIONS):
        var segs = InlineArray[UInt16, 8](fill=0)
        for i in range(8):
            segs[i] = UInt16(rng.next() & 0xFFFF)
        var port = UInt16(rng.next() & 0xFFFF)
        var scope = UInt32(rng.next() & 0xFFFFFFFF)
        var addr = SocketAddrV6(
            segs[0], segs[1], segs[2], segs[3],
            segs[4], segs[5], segs[6], segs[7],
            port=port,
            scope_id=scope,
        )
        var back = addr.addr_stor().to_v6()
        for i in range(8):
            assert_equal(
                Int(back.segments()[i]),
                Int(segs[i]),
                "segment " + String(i) + " changed across the round trip",
            )
        assert_equal(Int(back.port), Int(port))
        assert_equal(Int(back.scope_id), Int(scope))


# ===----------------------------------------------------------------------=== #
# 5. _next_pow2
# ===----------------------------------------------------------------------=== #


def property_next_pow2_is_the_least_power_at_or_above(
    mut rng: Xorshift64,
) raises:
    """`_next_pow2(n)` is a power of two, `>= n` and `< 2n` for `n >= 1`.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var n: Int
        var pick = rng.below(3)
        if pick == 0:
            n = rng.between(1, 4096)
        elif pick == 1:
            n = rng.between(1, 1 << 30)
        else:
            var k = rng.between(0, 40)
            n = (1 << k) + rng.between(-1, 1)
            if n < 1:
                n = 1
        var p = _next_pow2(n)
        assert_true(p >= 1 and (p & (p - 1)) == 0, "not a power of two")
        assert_true(p >= n, "below n for " + String(n))
        assert_true(p < 2 * n, "not the least power for " + String(n))
    assert_equal(_next_pow2(32768), 32768)
    assert_equal(_next_pow2(1), 1)
    assert_equal(_next_pow2(0), 1)


# ===----------------------------------------------------------------------=== #
# 6. Completion flag decoders
# ===----------------------------------------------------------------------=== #


def property_completion_flags_decode_bit_by_bit(mut rng: Xorshift64) raises:
    """`buffer_id` is `flags >> 16` iff the BUFFER bit is set; `has_more` iff MORE.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var flags = UInt32(rng.next() & 0xFFFFFFFF)
        if rng.chance(4):
            flags = UInt32(rng.below(4))
        var id = buffer_id(flags)
        if (flags & UInt32(IORING_CQE_F_BUFFER)) != 0:
            assert_true(id, "BUFFER bit set: an id is present")
            assert_equal(
                Int(id.value()), Int(flags >> UInt32(IORING_CQE_BUFFER_SHIFT))
            )
            assert_equal(Int(id.value()), Int(flags >> 16) & 0xFFFF)
        else:
            assert_true(not id, "BUFFER bit clear: no id")
        assert_equal(has_more(flags), (flags & UInt32(IORING_CQE_F_MORE)) != 0)


# ===----------------------------------------------------------------------=== #
# 7. transferred() clamp
# ===----------------------------------------------------------------------=== #


def property_transferred_is_clamped_to_the_buffer(mut rng: Xorshift64) raises:
    """`transferred()` has `min(count, len(buffer))` bytes for `count >= 0`.

    Both `TransferResult` and `MessageResult` are checked, for counts
    inside the buffer, past it and at `Int.MAX`; the view starts at the
    buffer's first byte.

    Args:
        rng: The generator.
    """
    for _ in range(ITERATIONS):
        var n = rng.between(0, 256)
        var count = rng.between(0, 600)
        if rng.chance(8):
            count = Int.MAX
        var expect = min(count, n)
        var buf = rng.bytes(n)
        var res = TransferResult(count, buf^)
        var view = res.transferred()
        assert_equal(
            len(view),
            expect,
            "TransferResult count " + String(count) + " over " + String(n),
        )
        if len(view) > 0:
            assert_equal(Int(view.unsafe_ptr()), Int(res._buf.unsafe_ptr()))
        var again = rng.bytes(n)
        var msg = MessageResult(count, Message(again^), 0)
        var view2 = msg.transferred()
        assert_equal(
            len(view2),
            expect,
            "MessageResult count " + String(count) + " over " + String(n),
        )


def property_transferred_treats_a_negative_count_as_empty(
    mut rng: Xorshift64,
) raises:
    """`transferred()` is empty for `count < 0`: `min(max(count, 0), len)`.

    Without the floor a negative `count` becomes a negative slice end,
    which aborts the process under `ASSERT=all`; the pinned case is
    `count = -1` over an empty buffer. Neither `WatchLoop` verb builds
    a result with a negative count, so only a direct constructor call
    reaches this.

    Args:
        rng: The generator.
    """
    var small = TransferResult(-1, List[UInt8]())
    assert_equal(len(small.transferred()), 0, "a negative count moves nothing")
    for _ in range(ITERATIONS):
        var n = rng.between(0, 256)
        var count = rng.between(-600, -1)
        if rng.chance(8):
            count = Int.MIN
        var buf = rng.bytes(n)
        var res = TransferResult(count, buf^)
        assert_equal(
            len(res.transferred()),
            0,
            "TransferResult count " + String(count) + " over " + String(n),
        )
        var again = rng.bytes(n)
        var msg = MessageResult(count, Message(again^), 0)
        assert_equal(
            len(msg.transferred()),
            0,
            "MessageResult count " + String(count) + " over " + String(n),
        )


# ===----------------------------------------------------------------------=== #
# main
# ===----------------------------------------------------------------------=== #


def _run_all(mut rng: Xorshift64) raises:
    """Run every property, in order, on one generator.

    Args:
        rng: The generator all properties draw from.
    """
    property_cmsg_walker_stays_in_bounds_and_terminates(rng)
    property_cmsg_align_rounds_up_to_eight(rng)
    property_ecn_reads_the_low_two_bits(rng)
    property_delivery_header_roundtrips_and_clamps(rng)
    property_delivery_region_clamps_both_ends(rng)
    property_short_delivery_buffer_reads_zero(rng)
    property_addr_len_is_clamped_to_the_slot(rng)
    property_family_decodes_only_known_ids(rng)
    property_ipv4_mapped_is_exactly_the_ffff_prefix(rng)
    property_v6_storage_round_trip_keeps_the_address(rng)
    property_next_pow2_is_the_least_power_at_or_above(rng)
    property_completion_flags_decode_bit_by_bit(rng)
    property_transferred_is_clamped_to_the_buffer(rng)
    property_transferred_treats_a_negative_count_as_empty(rng)


def main() raises:
    var rng = Xorshift64(SEED)
    var start = perf_counter_ns()
    try:
        _run_all(rng)
    except e:
        print("FAIL: test_properties.mojo seed=", hex(SEED), "state=", hex(rng.state))
        raise e
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    print(
        "PASS: test_properties.mojo (",
        ITERATIONS,
        "iterations per property,",
        elapsed_ms,
        "ms)",
    )
