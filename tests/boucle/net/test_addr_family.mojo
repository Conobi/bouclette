"""AddrFamily equality and decoding from a sockaddr byte image.

The kernel reports an address family as the first two bytes of every
sockaddr, in host order. `AddrFamily.from_sockaddr` is the one place
that read happens; it returns UNSPEC for a short image or a family
boucle does not model.
"""

from std.memory import Pointer
from std.sys.info import size_of
from std.testing import assert_equal, assert_true

from boucle.net.addr import SocketAddrStorAny, SocketAddrV4, SocketAddrV6
from boucle.net.options import AddrFamily
from boucle.socle.platform import sockaddr_in6


def test_families_compare_by_id() raises:
    """Equality and inequality follow the AF_* id."""
    assert_true(AddrFamily.INET == AddrFamily.INET)
    assert_true(AddrFamily.INET != AddrFamily.INET6)
    assert_true(AddrFamily.UNSPEC != AddrFamily.INET)
    assert_true(AddrFamily(unsafe_id=10) == AddrFamily.INET6)


def test_from_sockaddr_reads_the_family_prefix() raises:
    """The first two bytes decode to INET, INET6 or UNIX."""
    var v4 = SocketAddrStorAny(SocketAddrV4(127, 0, 0, 1, port=1).addr_stor())
    var v4_bytes = Span[UInt8, ImmStaticOrigin](
        unsafe_ptr=v4.addr_unsafe_ptr(), length=Int(v4.addr_len())
    )
    assert_true(AddrFamily.from_sockaddr(v4_bytes) == AddrFamily.INET)

    var v6 = SocketAddrStorAny(
        SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=1).addr_stor()
    )
    var v6_bytes = Span[UInt8, ImmStaticOrigin](
        unsafe_ptr=v6.addr_unsafe_ptr(), length=Int(v6.addr_len())
    )
    assert_true(AddrFamily.from_sockaddr(v6_bytes) == AddrFamily.INET6)

    var unix = List[UInt8](length=4, fill=0)
    # Byte-level checks assume little-endian, true for x86_64 and aarch64 Linux.
    unix[0] = 1
    assert_true(AddrFamily.from_sockaddr(Span(unix)) == AddrFamily.UNIX)


def test_from_sockaddr_unspec_for_short_or_unknown() raises:
    """Fewer than two bytes, or a family boucle does not model, is UNSPEC."""
    var one = List[UInt8](length=1, fill=2)
    assert_true(AddrFamily.from_sockaddr(Span(one)) == AddrFamily.UNSPEC)
    var none = List[UInt8]()
    assert_true(AddrFamily.from_sockaddr(Span(none)) == AddrFamily.UNSPEC)
    var netlink = List[UInt8](length=2, fill=0)
    # Byte-level checks assume little-endian, true for x86_64 and aarch64 Linux.
    netlink[0] = 16
    assert_true(AddrFamily.from_sockaddr(Span(netlink)) == AddrFamily.UNSPEC)
    var raw = sockaddr_in6()
    var zero = Span(unsafe_ptr=Pointer(to=raw).unsafe_bitcast[UInt8](), length=size_of[sockaddr_in6]())
    assert_true(AddrFamily.from_sockaddr(zero) == AddrFamily.UNSPEC)


def test_is_ipv4_mapped() raises:
    """Only ::ffff:a.b.c.d matches; every other shape below does not.

    Shapes covered: ::ffff:127.0.0.1 (mapped), ::ffff:0.0.0.0 (mapped,
    zero payload), ::1 (loopback), ::127.0.0.1 (deprecated
    IPv4-compatible), ::ffff:0:127.0.0.1 (SIIT), 2001:db8:: (doc
    prefix), :: (unspecified).
    """
    var mapped = SocketAddrV6(0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001, port=1)
    assert_true(mapped.is_ipv4_mapped())
    var mapped_zero = SocketAddrV6(0, 0, 0, 0, 0, 0xFFFF, 0, 0, port=1)
    assert_true(mapped_zero.is_ipv4_mapped())
    var loopback = SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=1)
    assert_true(not loopback.is_ipv4_mapped())
    var compatible = SocketAddrV6(0, 0, 0, 0, 0, 0, 0x7F00, 0x0001, port=1)
    assert_true(not compatible.is_ipv4_mapped())
    var siit = SocketAddrV6(0, 0, 0, 0, 0xFFFF, 0, 0x7F00, 0x0001, port=1)
    assert_true(not siit.is_ipv4_mapped())
    var doc_prefix = SocketAddrV6(
        0x2001, 0x0DB8, 0, 0, 0, 0xFFFF, 0, 1, port=1
    )
    assert_true(not doc_prefix.is_ipv4_mapped())
    var unspecified = SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 0, port=1)
    assert_true(not unspecified.is_ipv4_mapped())


def main() raises:
    test_families_compare_by_id()
    test_from_sockaddr_reads_the_family_prefix()
    test_from_sockaddr_unspec_for_short_or_unknown()
    test_is_ipv4_mapped()
    print("PASS: test_addr_family.mojo")
