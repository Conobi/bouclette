from boucle.net.addr import (
    SocketAddrV4,
    SocketAddrV6,
    SocketAddrStorV4,
    SocketAddrStorV6,
)
from std.testing import assert_equal, assert_true
from std.sys.info import size_of


def test_addr() raises:
    # --- SocketAddrV4 ---
    var addr4 = SocketAddrV4(127, 0, 0, 1, port=8080)
    assert_equal(addr4.port, UInt16(8080))
    assert_equal(addr4.ip.octets[0], UInt8(127))
    assert_equal(addr4.ip.octets[3], UInt8(1))

    # Octets ref access
    assert_equal(addr4.octets()[0], UInt8(127))

    # Storage conversion
    var stor4 = addr4.addr_stor()
    assert_equal(Int(stor4.addr.sin_family), 2)  # AF_INET
    assert_equal(size_of[SocketAddrStorV4](), 16)

    # --- SocketAddrV6 ---
    var addr6 = SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=443, scope_id=0)
    assert_equal(addr6.port, UInt16(443))
    assert_equal(addr6.scope_id, UInt32(0))

    # Segments ref access
    assert_equal(addr6.segments()[7], UInt16(1))

    # Storage conversion
    var stor6 = addr6.addr_stor()
    assert_equal(Int(stor6.addr.sin6_family), 10)  # AF_INET6
    assert_equal(size_of[SocketAddrStorV6](), 28)

    # Verify IPv6 byte layout: ::1 should have byte 15 = 1, all others = 0
    # The flattened sockaddr_in6 stores address bytes in sin6_addr_a/b/c/d.
    # Byte 15 is the last byte of sin6_addr_d.
    var addr_d_ptr = Pointer(to=stor6.addr.sin6_addr_d).unsafe_bitcast[UInt8]()
    assert_equal(
        Int(addr_d_ptr[unsafe_offset=3]),
        1,
        "last byte of ::1 must be 1",
    )
    var addr_a_ptr = Pointer(to=stor6.addr.sin6_addr_a).unsafe_bitcast[UInt8]()
    assert_equal(
        Int(addr_a_ptr[unsafe_offset=0]),
        0,
        "first byte of ::1 must be 0",
    )

    # Verify 2001:db8::1 byte layout
    var addr6b = SocketAddrV6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1, port=80)
    var stor6b = addr6b.addr_stor()
    var b_addr_a_ptr = Pointer(to=stor6b.addr.sin6_addr_a).unsafe_bitcast[UInt8]()
    assert_equal(Int(b_addr_a_ptr[unsafe_offset=0]), 0x20)
    assert_equal(Int(b_addr_a_ptr[unsafe_offset=1]), 0x01)
    assert_equal(Int(b_addr_a_ptr[unsafe_offset=2]), 0x0d)
    assert_equal(Int(b_addr_a_ptr[unsafe_offset=3]), 0xb8)
    var b_addr_d_ptr = Pointer(to=stor6b.addr.sin6_addr_d).unsafe_bitcast[UInt8]()
    assert_equal(Int(b_addr_d_ptr[unsafe_offset=3]), 0x01)


def _assert_round_trip(addr: SocketAddrV6) raises:
    """Check every word, the port and the scope of `addr` survive storage.

    Args:
        addr: The address to push through `addr_stor().to_v6()`.
    """
    var back = addr.addr_stor().to_v6()
    for i in range(8):
        assert_equal(
            Int(back.segments()[i]),
            Int(addr.segments()[i]),
            "segment " + String(i) + " changed across the storage round trip",
        )
    assert_equal(Int(back.port), Int(addr.port))
    assert_equal(Int(back.scope_id), Int(addr.scope_id))


def test_v6_storage_round_trip() raises:
    """`addr_stor().to_v6()` returns all eight words for mapped and plain.

    `to_v6` must read `sin6_addr_a/b/c/d` as the fields the constructor
    wrote, not through a pointer offset from the first word; a mapped
    peer that lost its words after `sin6_addr_a` would stop answering
    `is_ipv4_mapped`, and `Message.set_ecn` picks IP_TOS on that answer.
    """
    var mapped = SocketAddrV6(
        0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101, port=4433, scope_id=7
    )
    _assert_round_trip(mapped)
    assert_true(
        mapped.addr_stor().to_v6().is_ipv4_mapped(),
        "a mapped address must stay mapped across the storage round trip",
    )
    var plain = SocketAddrV6(
        0x2001, 0x0DB8, 0x1234, 0x5678, 0x9ABC, 0xDEF0, 0x0F0F, 0xF0F0, port=53
    )
    _assert_round_trip(plain)
    assert_true(not plain.addr_stor().to_v6().is_ipv4_mapped())


def main() raises:
    test_addr()
    test_v6_storage_round_trip()
    print("PASS: test_addr.mojo")
