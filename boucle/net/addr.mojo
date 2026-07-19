"""Socket address types with kernel storage conversion.

Provides SocketAddrV4 / SocketAddrV6 (user-facing) and their storage
counterparts SocketAddrStorV4 / SocketAddrStorV6 that map directly to
the kernel's sockaddr_in / sockaddr_in6 layouts.

Traits
------
- SocketAddr(Defaultable)    — immutable address with compile-time length
- SocketAddrMut(Defaultable) — mutable address (for recvfrom)
- SocketAddrStor             — types that can produce a SocketAddr storage
- SocketAddrStorMut          — types that can produce a SocketAddrMut storage
"""

from std.sys.info import align_of, size_of
from std.memory import UnsafePointer

from boucle.net.ip import IpAddrV4, IpAddrV6
from boucle.net.options import AddrFamily
from boucle._sys.linux.raw.ctypes import c_uint
from boucle._sys.linux.raw.utils import _to_be
from boucle._sys.linux.raw import (
    __be32,
    sockaddr_in,
    sockaddr_in6,
    socklen_t,
)


# ===----------------------------------------------------------------------=== #
# Traits
# ===----------------------------------------------------------------------=== #


trait SocketAddr(Defaultable, ImplicitlyDestructible):
    comptime ADDR_LEN: socklen_t

    def addr_unsafe_ptr(
        ref self,
    ) -> UnsafePointer[UInt8, StaticConstantOrigin]:
        ...


trait SocketAddrMut(Defaultable, ImplicitlyDestructible):
    def addr_unsafe_ptr(
        ref self,
    ) -> UnsafePointer[UInt8, StaticConstantOrigin]:
        ...

    def len_unsafe_ptr(
        ref self,
    ) -> UnsafePointer[Int8, StaticConstantOrigin]:
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
    ) -> UnsafePointer[UInt8, StaticConstantOrigin]:
        return self.addr.addr_unsafe_ptr()

    @always_inline
    def len_unsafe_ptr(
        ref self,
    ) -> UnsafePointer[Int8, StaticConstantOrigin]:
        return UnsafePointer[Int8, StaticConstantOrigin](
            unsafe_from_address=Int(UnsafePointer(to=self.len))
        )


# ===----------------------------------------------------------------------=== #
# IPv4 storage and address
# ===----------------------------------------------------------------------=== #


struct SocketAddrStorV4(TrivialRegisterPassable, SocketAddr):
    comptime ADDR_LEN: socklen_t = socklen_t(size_of[sockaddr_in]())

    var addr: sockaddr_in

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 16
        comptime assert align_of[Self]() == 4
        self.addr = sockaddr_in()

    @always_inline
    def __init__[
        origin: ImmutOrigin
    ](out self, ref [origin] addr: SocketAddrV4):
        comptime assert size_of[Self]() == 16
        comptime assert align_of[Self]() == 4
        comptime assert size_of[addr.Octets]() == size_of[__be32]()
        comptime assert align_of[addr.Octets]() == align_of[__be32]()


        self.addr = sockaddr_in()
        self.addr.sin_family = AddrFamily.INET.id
        self.addr.sin_port = _to_be(addr.port)
        # Reinterpret the 4 octets as a __be32 (network-order u32).
        self.addr.sin_addr_s_addr = (
            UnsafePointer(to=addr.octets())
            .bitcast[__be32]()
            .load[alignment = align_of[addr.Octets]()]()
        )

    @always_inline
    def addr_unsafe_ptr(
        ref self,
    ) -> UnsafePointer[UInt8, StaticConstantOrigin]:
        return UnsafePointer[UInt8, StaticConstantOrigin](
            unsafe_from_address=Int(UnsafePointer(to=self.addr))
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


struct SocketAddrStorV6(TrivialRegisterPassable, SocketAddr):
    comptime ADDR_LEN: socklen_t = socklen_t(size_of[sockaddr_in6]())

    var addr: sockaddr_in6

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 28
        comptime assert align_of[Self]() == 4
        self.addr = sockaddr_in6()

    @always_inline
    def __init__[
        origin: ImmutOrigin
    ](out self, ref [origin] addr: SocketAddrV6):
        comptime assert size_of[Self]() == 28
        comptime assert align_of[Self]() == 4

        # Convert 8x uint16 segments (host order) to big-endian bytes,
        # then pack into four UInt32 fields (sin6_addr_a/b/c/d).
        # _to_be byte-swaps each uint16 to network (big-endian) order.
        var be_segs = _to_be(addr.segments())
        var src = UnsafePointer(to=be_segs).bitcast[UInt32]()

        self.addr = sockaddr_in6()
        self.addr.sin6_family = AddrFamily.INET6.id
        self.addr.sin6_port = _to_be(addr.port)
        self.addr.sin6_flowinfo = 0
        self.addr.sin6_addr_a = src[0]
        self.addr.sin6_addr_b = src[1]
        self.addr.sin6_addr_c = src[2]
        self.addr.sin6_addr_d = src[3]
        self.addr.sin6_scope_id = addr.scope_id

    @always_inline
    def addr_unsafe_ptr(
        ref self,
    ) -> UnsafePointer[UInt8, StaticConstantOrigin]:
        return UnsafePointer[UInt8, StaticConstantOrigin](
            unsafe_from_address=Int(UnsafePointer(to=self.addr))
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
