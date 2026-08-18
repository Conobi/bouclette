from boucle.net.ip import IpAddrV4, IpAddrV6
from std.testing import assert_equal


def test_ip() raises:
    var v4 = IpAddrV4(127, 0, 0, 1)
    assert_equal(v4.octets[0], UInt8(127))
    assert_equal(v4.octets[1], UInt8(0))
    assert_equal(v4.octets[2], UInt8(0))
    assert_equal(v4.octets[3], UInt8(1))

    var v4_zero = IpAddrV4(0, 0, 0, 0)
    assert_equal(v4_zero.octets[0], UInt8(0))

    var v6 = IpAddrV6(0, 0, 0, 0, 0, 0, 0, 1)
    assert_equal(v6.segments[0], UInt16(0))
    assert_equal(v6.segments[7], UInt16(1))

    var v6_full = IpAddrV6(0x2001, 0x0db8, 0x85a3, 0, 0, 0x8a2e, 0x0370, 0x7334)
    assert_equal(v6_full.segments[0], UInt16(0x2001))
    assert_equal(v6_full.segments[1], UInt16(0x0db8))
    assert_equal(v6_full.segments[7], UInt16(0x7334))


def main() raises:
    test_ip()
    print("PASS: test_ip.mojo")
