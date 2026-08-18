from boucle.net.ip import IpAddrV4, IpAddrV6
from std.testing import assert_equal


def test_ip_display() raises:
    # IPv4 canonical decimal form.
    assert_equal(String(IpAddrV4(127, 0, 0, 1)), "127.0.0.1")
    assert_equal(String(IpAddrV4(0, 0, 0, 0)), "0.0.0.0")
    assert_equal(String(IpAddrV4(255, 255, 255, 255)), "255.255.255.255")
    assert_equal(String(IpAddrV4(1, 2, 3, 4)), "1.2.3.4")

    # IPv6 — no `::` compression; explicit 8-segment lowercase-hex form.
    assert_equal(
        String(IpAddrV6(0x2001, 0x0db8, 0x85a3, 0, 0, 0x8a2e, 0x0370, 0x7334)),
        "2001:db8:85a3:0:0:8a2e:370:7334",
    )
    assert_equal(
        String(IpAddrV6(0, 0, 0, 0, 0, 0, 0, 1)),
        "0:0:0:0:0:0:0:1",
    )
    assert_equal(
        String(IpAddrV6(0xff02, 0, 0, 0, 0, 0, 0, 0x0001)),
        "ff02:0:0:0:0:0:0:1",
    )


def main() raises:
    test_ip_display()
    print("PASS: test_ip_display.mojo")
