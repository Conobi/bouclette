"""IP address types.

IpAddrV4 holds 4 octets, IpAddrV6 holds 8 segments of 16 bits.
Both are TrivialRegisterPassable value types.
"""

from std.format import Writable, Writer


@always_inline
def _write_hex_segment[W: Writer](mut writer: W, v: UInt16):
    """Write `v` as 1-4 lowercase hex digits, no leading zeros."""
    if v == 0:
        writer.write_string("0")
        return
    var digits = Array[UInt8, 4](fill=0)
    var n = 0
    var x = UInt32(v)
    while x > 0:
        var d = Int(x & UInt32(0xF))
        digits[n] = UInt8(48 + d) if d < 10 else UInt8(87 + d)
        x = x >> 4
        n += 1
    # Write in reverse — digits is little-endian here.
    var out = Array[UInt8, 4](fill=0)
    for i in range(n):
        out[i] = digits[n - 1 - i]
    var slc = StringSlice(
        unsafe_from_utf8=Span[UInt8, origin_of(out)](unsafe_ptr=out.unsafe_ptr(), length=n)
    )
    writer.write_string(slc)


struct IpAddrV4(TrivialRegisterPassable, Writable):
    """An IPv4 address (4 octets)."""

    comptime Octets = SIMD[DType.uint8, 4]
    var octets: Self.Octets

    @always_inline
    def __init__(out self, a: UInt8, b: UInt8, c: UInt8, d: UInt8):
        self.octets = Self.Octets(a, b, c, d)

    @staticmethod
    def parse(s: String) -> Optional[IpAddrV4]:
        """Strict dotted-quad parser.

        Accepts exactly four decimal octets in `0..=255` separated by single
        `.`s. Returns `None` for any malformed input.
        """
        var octets = SIMD[DType.uint8, 4](0, 0, 0, 0)
        var octet_idx = 0
        var current = UInt32(0)
        var has_digit = False
        var bs = s.as_bytes()
        var n = len(bs)
        if n == 0:
            return None

        for i in range(n):
            var b = Int(bs[i])
            if b == 46:  # ord('.')
                if not has_digit:
                    return None
                if octet_idx >= 3:
                    return None
                octets[octet_idx] = UInt8(current)
                octet_idx += 1
                current = UInt32(0)
                has_digit = False
            elif b >= 48 and b <= 57:
                current = current * UInt32(10) + UInt32(b - 48)
                if current > UInt32(255):
                    return None
                has_digit = True
            else:
                return None

        if not has_digit:
            return None
        if octet_idx != 3:
            return None
        octets[3] = UInt8(current)
        return Optional(IpAddrV4(octets[0], octets[1], octets[2], octets[3]))

    def write_to[W: Writer](self, mut writer: W):
        """Writes `a.b.c.d` in decimal."""
        writer.write(
            Int(self.octets[0]), ".",
            Int(self.octets[1]), ".",
            Int(self.octets[2]), ".",
            Int(self.octets[3]),
        )


struct IpAddrV6(TrivialRegisterPassable, Writable):
    """An IPv6 address (8 segments of 16 bits)."""

    comptime Segments = SIMD[DType.uint16, 8]
    var segments: Self.Segments

    @always_inline
    def __init__(
        out self,
        a: UInt16,
        b: UInt16,
        c: UInt16,
        d: UInt16,
        e: UInt16,
        f: UInt16,
        g: UInt16,
        h: UInt16,
    ):
        self.segments = Self.Segments(a, b, c, d, e, f, g, h)

    def write_to[W: Writer](self, mut writer: W):
        """Writes 8 lowercase-hex segments separated by `:`.

        No `::` compression — explicit canonical 8-segment form. Compression
        is a follow-up polish pass.
        """
        for i in range(8):
            if i != 0:
                writer.write_string(":")
            _write_hex_segment(writer, self.segments[i])
