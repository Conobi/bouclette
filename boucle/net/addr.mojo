"""Socket address types with kernel storage conversion.

Provides SocketAddrV4 / SocketAddrV6 (user-facing) and their storage
counterparts SocketAddrStorV4 / SocketAddrStorV6 that map directly to
the kernel's sockaddr_in / sockaddr_in6 layouts, plus SocketAddrStorAny,
a family-agnostic storage sized for the largest of them so one field
can hold the target of an operation for either family.

Traits
------
- SocketAddr(Defaultable)    — immutable address with compile-time length
- SocketAddrMut(Defaultable) — mutable address (for recvfrom)
- SocketAddrStor             — types that can produce a SocketAddr storage
- SocketAddrStorMut          — types that can produce a SocketAddrMut storage
"""

from std.sys.info import align_of, size_of
from std.memory import Pointer

from boucle.net.ip import IpAddrV4, IpAddrV6
from boucle.net.options import AddrFamily
from boucle.socle.platform import (
    __be32,
    _to_be,
    c_uint,
    sockaddr_in,
    sockaddr_in6,
    socklen_t,
)


# ===----------------------------------------------------------------------=== #
# Traits
# ===----------------------------------------------------------------------=== #


trait SocketAddr(Defaultable, Deinitable, Movable):
    comptime ADDR_LEN: socklen_t

    def addr_unsafe_ptr(
        ref self,
    ) -> Pointer[UInt8, ImmStaticOrigin]:
        ...


trait SocketAddrMut(Defaultable, Deinitable):
    def addr_unsafe_ptr(
        ref self,
    ) -> Pointer[UInt8, ImmStaticOrigin]:
        ...

    def len_unsafe_ptr(
        ref self,
    ) -> Pointer[Int8, ImmStaticOrigin]:
        ...


trait SocketAddrStor:
    comptime AddrStorType: SocketAddr

    def addr_stor(ref self, out result: Self.AddrStorType):
        ...


trait SocketAddrStorMut:
    comptime AddrStorMutType: SocketAddrMut

    @staticmethod
    def addr_stor_mut(out result: Self.AddrStorMutType):
        ...


# ===----------------------------------------------------------------------=== #
# Generic mutable storage wrapper
# ===----------------------------------------------------------------------=== #


struct SocketAddrStorAnyMut[Addr: SocketAddr](SocketAddrMut):
    var addr: Self.Addr
    var len: socklen_t

    @always_inline
    def __init__(out self):
        self.addr = Self.Addr()
        self.len = Self.Addr.ADDR_LEN

    @always_inline
    def addr_unsafe_ptr(
        ref self,
    ) -> Pointer[UInt8, ImmStaticOrigin]:
        return self.addr.addr_unsafe_ptr()

    @always_inline
    def len_unsafe_ptr(
        ref self,
    ) -> Pointer[Int8, ImmStaticOrigin]:
        return Pointer[Int8, ImmStaticOrigin](
            unsafe_from_address=Int(Pointer(to=self.len))
        )


# ===----------------------------------------------------------------------=== #
# Family-agnostic storage
# ===----------------------------------------------------------------------=== #


struct SocketAddrStorAny(ImplicitlyCopyable, Movable):
    """Storage large enough for any supported sockaddr, plus its length.

    The kernel takes a socket address as an opaque pointer and a byte
    count, so an operation that must hold its target address for the
    life of the request does not need to know the family — it needs the
    bytes and how many of them are meaningful. This struct copies a
    concrete storage (SocketAddrStorV4, SocketAddrStorV6, ...) into a
    buffer laid out as the largest supported sockaddr and records the
    source's length.

    Fields:
        addr: Byte buffer laid out as sockaddr_in6, the largest sockaddr
              supported. Only the first `len` bytes are meaningful.
        len: Number of meaningful bytes in `addr` (0 when default-built).
    """

    var addr: sockaddr_in6
    var len: socklen_t

    @always_inline
    def __init__(out self):
        """Construct an empty storage: all bytes zero, length zero."""
        self.addr = sockaddr_in6()
        self.len = 0

    def __init__[Addr: SocketAddr](out self, ref stor: Addr):
        """Copy a concrete sockaddr storage into the family-agnostic buffer.

        Copies `Addr.ADDR_LEN` bytes from the source storage; any bytes
        past that length stay zero.

        Parameters:
            Addr: The concrete storage type, e.g. SocketAddrStorV4.

        Args:
            stor: The storage whose bytes are copied.
        """
        comptime assert Int(Addr.ADDR_LEN) <= size_of[sockaddr_in6](), (
            "sockaddr storage larger than the largest supported family"
        )
        self.addr = sockaddr_in6()
        self.len = Addr.ADDR_LEN
        var n = Int(self.len)
        var src = stor.addr_unsafe_ptr()
        var dst = Pointer(to=self.addr).unsafe_bitcast[UInt8]()
        for i in range(n):
            dst[unsafe_offset=i] = src[unsafe_offset=i]

    @always_inline
    def addr_unsafe_ptr(
        ref self,
    ) -> Pointer[UInt8, ImmStaticOrigin]:
        """Return a byte pointer to the start of the stored sockaddr.

        Returns:
            A pointer to the first byte of `addr`; valid for as long as
            this struct is not moved or destroyed.
        """
        return Pointer[UInt8, ImmStaticOrigin](
            unsafe_from_address=Int(Pointer(to=self.addr))
        )

    @always_inline
    def addr_len(self) -> socklen_t:
        """Return the number of meaningful bytes in the stored sockaddr.

        Returns:
            The source storage's ADDR_LEN, or 0 for a default-built value.
        """
        return self.len


# ===----------------------------------------------------------------------=== #
# IPv4 storage and address
# ===----------------------------------------------------------------------=== #


struct SocketAddrStorV4(ImplicitlyCopyable, Movable, SocketAddr):
    comptime ADDR_LEN: socklen_t = socklen_t(size_of[sockaddr_in]())

    var addr: sockaddr_in

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 16
        comptime assert align_of[Self]() == 4
        self.addr = sockaddr_in()

    @always_inline
    def __init__[
        origin: ImmOrigin
    ](out self, ref [origin] addr: SocketAddrV4):
        comptime assert size_of[Self]() == 16
        comptime assert align_of[Self]() == 4
        comptime assert size_of[addr.Octets]() == size_of[__be32]()
        comptime assert align_of[addr.Octets]() == align_of[__be32]()


        self.addr = sockaddr_in()
        self.addr.sin_family = AddrFamily.INET.id
        self.addr.sin_port = _to_be[DType.uint16, 1](addr.port)
        # Reinterpret the 4 octets as a __be32 (network-order u32).
        self.addr.sin_addr_s_addr = (
            Pointer(to=addr.octets())
            .unsafe_bitcast[__be32]()
            .unsafe_load[alignment = align_of[addr.Octets]()]()
        )

    @always_inline
    def addr_unsafe_ptr(
        ref self,
    ) -> Pointer[UInt8, ImmStaticOrigin]:
        return Pointer[UInt8, ImmStaticOrigin](
            unsafe_from_address=Int(Pointer(to=self.addr))
        )

    @always_inline
    def to_v4(self) -> SocketAddrV4:
        """Convert kernel sockaddr_in to user-facing SocketAddrV4.

        Byte-swaps port from network order to host order and extracts
        the four IP octets.
        """
        var port = _to_be[DType.uint16, 1](self.addr.sin_port)
        var octets = Pointer(to=self.addr.sin_addr_s_addr).unsafe_bitcast[
            UInt8
        ]()
        return SocketAddrV4(
            octets[unsafe_offset=0],
            octets[unsafe_offset=1],
            octets[unsafe_offset=2],
            octets[unsafe_offset=3],
            port=port,
        )


comptime SocketAddrStorMutV4 = SocketAddrStorAnyMut[SocketAddrStorV4]


struct SocketAddrV4(TrivialRegisterPassable, SocketAddrStor, SocketAddrStorMut):
    comptime AddrStorType: SocketAddr = SocketAddrStorV4
    comptime AddrStorMutType: SocketAddrMut = SocketAddrStorMutV4
    comptime Octets = IpAddrV4.Octets

    var ip: IpAddrV4
    var port: UInt16

    @always_inline
    def __init__(
        out self, a: UInt8, b: UInt8, c: UInt8, d: UInt8, *, port: UInt16
    ):
        self.ip = IpAddrV4(a, b, c, d)
        self.port = port

    @always_inline
    def octets(ref self) -> ref [self.ip.octets] Self.Octets:
        return self.ip.octets

    @always_inline
    def addr_stor(ref self, out result: Self.AddrStorType):
        result = Self.AddrStorType(self)

    @staticmethod
    @always_inline
    def addr_stor_mut(out result: Self.AddrStorMutType):
        result = Self.AddrStorMutType()


# ===----------------------------------------------------------------------=== #
# IPv6 storage and address
# ===----------------------------------------------------------------------=== #


struct SocketAddrStorV6(ImplicitlyCopyable, Movable, SocketAddr):
    comptime ADDR_LEN: socklen_t = socklen_t(size_of[sockaddr_in6]())

    var addr: sockaddr_in6

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 28
        comptime assert align_of[Self]() == 4
        self.addr = sockaddr_in6()

    @always_inline
    def __init__[
        origin: ImmOrigin
    ](out self, ref [origin] addr: SocketAddrV6):
        comptime assert size_of[Self]() == 28
        comptime assert align_of[Self]() == 4

        # Convert 8x uint16 segments (host order) to big-endian bytes,
        # then pack into four UInt32 fields (sin6_addr_a/b/c/d).
        # _to_be byte-swaps each uint16 to network (big-endian) order.
        var be_segs = _to_be[DType.uint16, 8](addr.segments())
        var src = Pointer(to=be_segs).unsafe_bitcast[UInt32]()

        self.addr = sockaddr_in6()
        self.addr.sin6_family = AddrFamily.INET6.id
        self.addr.sin6_port = _to_be[DType.uint16, 1](addr.port)
        self.addr.sin6_flowinfo = 0
        self.addr.sin6_addr_a = src[unsafe_offset=0]
        self.addr.sin6_addr_b = src[unsafe_offset=1]
        self.addr.sin6_addr_c = src[unsafe_offset=2]
        self.addr.sin6_addr_d = src[unsafe_offset=3]
        self.addr.sin6_scope_id = addr.scope_id

    @always_inline
    def addr_unsafe_ptr(
        ref self,
    ) -> Pointer[UInt8, ImmStaticOrigin]:
        return Pointer[UInt8, ImmStaticOrigin](
            unsafe_from_address=Int(Pointer(to=self.addr))
        )

    @always_inline
    def to_v6(self) -> SocketAddrV6:
        """Convert kernel sockaddr_in6 to user-facing SocketAddrV6.

        Byte-swaps port and segments from network order to host order.
        """
        var port = _to_be[DType.uint16, 1](self.addr.sin6_port)
        var src = Pointer(to=self.addr.sin6_addr_a).unsafe_bitcast[UInt32]()
        var be_segs = SIMD[DType.uint16, 8]()
        var seg_ptr = Pointer(to=be_segs).unsafe_bitcast[UInt32]()
        seg_ptr[unsafe_offset=0] = src[unsafe_offset=0]
        seg_ptr[unsafe_offset=1] = src[unsafe_offset=1]
        seg_ptr[unsafe_offset=2] = src[unsafe_offset=2]
        seg_ptr[unsafe_offset=3] = src[unsafe_offset=3]
        var segs = _to_be[DType.uint16, 8](be_segs)
        return SocketAddrV6(
            segs[0], segs[1], segs[2], segs[3],
            segs[4], segs[5], segs[6], segs[7],
            port=port,
            scope_id=self.addr.sin6_scope_id,
        )


comptime SocketAddrStorMutV6 = SocketAddrStorAnyMut[SocketAddrStorV6]


struct SocketAddrV6(TrivialRegisterPassable, SocketAddrStor, SocketAddrStorMut):
    comptime AddrStorType: SocketAddr = SocketAddrStorV6
    comptime AddrStorMutType: SocketAddrMut = SocketAddrStorMutV6
    comptime Segments = IpAddrV6.Segments

    var ip: IpAddrV6
    var port: UInt16
    var scope_id: UInt32

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
        *,
        port: UInt16,
        scope_id: UInt32 = 0,
    ):
        self.ip = IpAddrV6(a, b, c, d, e, f, g, h)
        self.port = port
        self.scope_id = scope_id

    @always_inline
    def segments(ref self) -> ref [self.ip.segments] Self.Segments:
        return self.ip.segments

    @always_inline
    def addr_stor(ref self, out result: Self.AddrStorType):
        result = Self.AddrStorType(self)

    @staticmethod
    @always_inline
    def addr_stor_mut(out result: Self.AddrStorMutType):
        result = Self.AddrStorMutType()
