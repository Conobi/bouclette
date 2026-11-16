"""SocketAddrStorAny.addr_bytes — a borrow-checked view of the wire bytes.

The span borrows the storage, so the compiler keeps the owner alive for
as long as the bytes are read. These tests also run at -O1/-O3, where a
dropped owner (the old raw-pointer pattern) read garbage.
"""

from std.testing import assert_equal

from bouclette.net.addr import SocketAddrStorAny, SocketAddrV4, SocketAddrV6


def _u16(b: Span[UInt8, _], at: Int) -> Int:
    # Host order (little-endian on x86_64/aarch64 Linux).
    return Int(b[at]) | (Int(b[at + 1]) << 8)


def _be16(b: Span[UInt8, _], at: Int) -> Int:
    return (Int(b[at]) << 8) | Int(b[at + 1])


def test_v4_wire_bytes() raises:
    var any = SocketAddrStorAny(
        SocketAddrV4(192, 168, 1, 7, port=8080).addr_stor()
    )
    var b = any.addr_bytes()
    assert_equal(len(b), 16)
    assert_equal(_u16(b, 0), 2, "family AF_INET")
    assert_equal(_be16(b, 2), 8080, "port, network order")
    assert_equal(Int(b[4]), 192)
    assert_equal(Int(b[5]), 168)
    assert_equal(Int(b[6]), 1)
    assert_equal(Int(b[7]), 7)
    for i in range(8, 16):
        assert_equal(Int(b[i]), 0, "sin_zero")


def test_v6_link_local_wire_bytes() raises:
    var any = SocketAddrStorAny(
        SocketAddrV6(
            0xFE80, 0, 0, 0, 0x0211, 0x22FF, 0xFE33, 0x4455,
            port=443,
            scope_id=0x01020304,
        ).addr_stor()
    )
    var b = any.addr_bytes()
    assert_equal(len(b), 28)
    assert_equal(_u16(b, 0), 10, "family AF_INET6")
    assert_equal(_be16(b, 2), 443, "port, network order")
    for i in range(4, 8):
        assert_equal(Int(b[i]), 0, "flowinfo")
    var expected: List[Int] = [
        0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0x02, 0x11, 0x22, 0xFF, 0xFE, 0x33,
        0x44, 0x55,
    ]
    for i in range(16):
        assert_equal(Int(b[8 + i]), expected[i], String("addr byte ", i))
    var scope = (
        Int(b[24]) | (Int(b[25]) << 8) | (Int(b[26]) << 16) | (Int(b[27]) << 24)
    )
    assert_equal(scope, 0x01020304, "scope id, host order")


def test_empty_storage_has_no_bytes() raises:
    var any = SocketAddrStorAny()
    assert_equal(len(any.addr_bytes()), 0)


def test_owner_only_used_through_the_accessor() raises:
    """The pattern that broke: no other use of the owner after the call."""
    var total = 0
    var b = SocketAddrStorAny(
        SocketAddrV6(0xFE80, 0, 0, 0, 0, 0, 0, 1, port=9, scope_id=3).addr_stor()
    ).addr_bytes()
    for i in range(len(b)):
        total += Int(b[i])
    assert_equal(_u16(b, 0), 10, "sin6_family survives")
    assert_equal(Int(b[24]), 3, "scope id survives")
    assert_equal(total, 10 + 9 + 0xFE + 0x80 + 1 + 3)


def main() raises:
    test_v4_wire_bytes()
    test_v6_link_local_wire_bytes()
    test_empty_storage_has_no_bytes()
    test_owner_only_used_through_the_accessor()
    print("PASS: test_addr_bytes.mojo")
