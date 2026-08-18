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
    var addr_d_ptr = UnsafePointer(to=stor6.addr.sin6_addr_d).bitcast[UInt8]()
    assert_equal(
        Int(addr_d_ptr[3]),
        1,
        "last byte of ::1 must be 1",
    )
    var addr_a_ptr = UnsafePointer(to=stor6.addr.sin6_addr_a).bitcast[UInt8]()
    assert_equal(
        Int(addr_a_ptr[0]),
        0,
        "first byte of ::1 must be 0",
    )

    # Verify 2001:db8::1 byte layout
    var addr6b = SocketAddrV6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1, port=80)
    var stor6b = addr6b.addr_stor()
    var b_addr_a_ptr = UnsafePointer(to=stor6b.addr.sin6_addr_a).bitcast[UInt8]()
    assert_equal(Int(b_addr_a_ptr[0]), 0x20)
    assert_equal(Int(b_addr_a_ptr[1]), 0x01)
    assert_equal(Int(b_addr_a_ptr[2]), 0x0d)
    assert_equal(Int(b_addr_a_ptr[3]), 0xb8)
    var b_addr_d_ptr = UnsafePointer(to=stor6b.addr.sin6_addr_d).bitcast[UInt8]()
    assert_equal(Int(b_addr_d_ptr[3]), 0x01)


def main() raises:
    test_addr()
    print("PASS: test_addr.mojo")
