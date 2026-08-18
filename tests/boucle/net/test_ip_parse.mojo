from boucle.net.ip import IpAddrV4
from std.testing import assert_true, assert_equal


def _expect(s: String, a: UInt8, b: UInt8, c: UInt8, d: UInt8) raises:
    var r = IpAddrV4.parse(s)
    assert_true(Bool(r), String("expected accept: ", s))
    var v = r.value()
    assert_equal(v.octets[0], a)
    assert_equal(v.octets[1], b)
    assert_equal(v.octets[2], c)
    assert_equal(v.octets[3], d)


def _reject(s: String) raises:
    var r = IpAddrV4.parse(s)
    assert_true(not r, String("expected reject: ", s))


def test_ip_parse() raises:
    # Canonical accepts.
    _expect("0.0.0.0", 0, 0, 0, 0)
    _expect("127.0.0.1", 127, 0, 0, 1)
    _expect("255.255.255.255", 255, 255, 255, 255)
    _expect("1.2.3.4", 1, 2, 3, 4)

    # Rejects.
    _reject("999.0.0.0")
    _reject("256.0.0.0")
    _reject("1.2.3")
    _reject("1..2.3.4")
    _reject("")
    _reject("abc")
    _reject("1.2.3.4.5")
    _reject("1.2.3.")
    _reject(".1.2.3.4")
    _reject("1.2.3.4 ")


def main() raises:
    test_ip_parse()
    print("PASS: test_ip_parse.mojo")
