"""Test SocketAddrStorAny — family-agnostic sockaddr storage.

A SocketAddrStorAny is built from a concrete storage (sockaddr_in or
sockaddr_in6) and remembers how many bytes of it are meaningful, so a
single field can hold the target of a connect for either family.
"""

from std.sys.info import size_of
from std.testing import assert_equal, assert_true

from boucle.net.addr import (
    SocketAddrStorAny,
    SocketAddrStorV4,
    SocketAddrStorV6,
    SocketAddrV4,
    SocketAddrV6,
)
from boucle.net.options import AddrFamily
from boucle.socle.platform import sockaddr_in6


def test_default_is_zeroed() raises:
    """The default storage has no family, no length, all-zero bytes."""
    var any = SocketAddrStorAny()
    assert_equal(Int(any.addr_len()), 0)
    var bytes = Pointer(to=any.addr).unsafe_bitcast[UInt8]()
    for i in range(size_of[sockaddr_in6]()):
        assert_equal(Int(bytes[unsafe_offset=i]), 0, "byte must be zero")
    assert_equal(
        Int(any.addr_unsafe_ptr()),
        Int(Pointer(to=any.addr)),
        "addr_unsafe_ptr must point at the stored bytes",
    )


def test_from_v4_storage() raises:
    """Built from a sockaddr_in, the length is 16 and the head bytes match.

    sockaddr_in and sockaddr_in6 share the family (offset 0) and port
    (offset 2) prefix, so the copied bytes must decode to AF_INET and
    carry the same network-order port as the source storage.
    """
    var addr4 = SocketAddrV4(127, 0, 0, 1, port=8080)
    var stor4 = addr4.addr_stor()
    var any = SocketAddrStorAny(stor4)

    assert_equal(Int(any.addr_len()), 16)
    assert_equal(Int(any.addr_len()), Int(SocketAddrStorV4.ADDR_LEN))
    assert_equal(Int(any.addr.sin6_family), 2, "family must be AF_INET")
    assert_equal(
        Int(any.addr.sin6_port),
        Int(stor4.addr.sin_port),
        "port bytes must match the source storage",
    )

    var src = Pointer(to=stor4.addr).unsafe_bitcast[UInt8]()
    var dst = Pointer(to=any.addr).unsafe_bitcast[UInt8]()
    for i in range(Int(SocketAddrStorV4.ADDR_LEN)):
        assert_equal(
            Int(dst[unsafe_offset=i]),
            Int(src[unsafe_offset=i]),
            String("byte ", i, " must match the source storage"),
        )
    # Bytes past the IPv4 length are untouched by the copy.
    for i in range(Int(SocketAddrStorV4.ADDR_LEN), size_of[sockaddr_in6]()):
        assert_equal(Int(dst[unsafe_offset=i]), 0, "tail must stay zero")


def test_from_v6_storage_round_trips() raises:
    """Built from a sockaddr_in6, the length is 28 and the address survives.

    Reinterpreting the stored bytes as a SocketAddrStorV6 and decoding
    them with to_v6() must give back the original address, port and
    scope id.
    """
    var addr6 = SocketAddrV6(
        0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1, port=443, scope_id=7
    )
    var stor6 = addr6.addr_stor()
    var any = SocketAddrStorAny(stor6)

    assert_equal(Int(any.addr_len()), 28)
    assert_equal(Int(any.addr_len()), Int(SocketAddrStorV6.ADDR_LEN))
    assert_equal(Int(any.addr.sin6_family), 10, "family must be AF_INET6")

    var back = SocketAddrStorV6()
    back.addr = any.addr
    var decoded = back.to_v6()
    assert_equal(decoded.port, UInt16(443))
    assert_equal(decoded.scope_id, UInt32(7))
    assert_equal(decoded.segments()[0], UInt16(0x2001))
    assert_equal(decoded.segments()[1], UInt16(0x0DB8))
    assert_equal(decoded.segments()[7], UInt16(1))
    for i in range(2, 7):
        assert_equal(decoded.segments()[i], UInt16(0))


def test_copy_keeps_bytes_and_len() raises:
    """A copy of the storage carries the same bytes and length."""
    var addr4 = SocketAddrV4(10, 0, 0, 2, port=9)
    var any = SocketAddrStorAny(addr4.addr_stor())
    var copy = any
    assert_equal(Int(copy.addr_len()), 16)
    var a = Pointer(to=any.addr).unsafe_bitcast[UInt8]()
    var b = Pointer(to=copy.addr).unsafe_bitcast[UInt8]()
    for i in range(size_of[sockaddr_in6]()):
        assert_equal(Int(a[unsafe_offset=i]), Int(b[unsafe_offset=i]))


def test_mutable_pointers_alias_the_storage() raises:
    """The mutable byte and length pointers write into the same fields."""
    var any = SocketAddrStorAny()
    var bytes = any.addr_unsafe_mut_ptr()
    assert_equal(Int(bytes), Int(Pointer(to=any.addr)))
    # sin6_family is a host-order UInt16; on little-endian x86_64/aarch64
    # its low byte comes first, so AF_INET6 (10) is byte 0 and byte 1 is 0.
    bytes[unsafe_offset=0] = UInt8(10)  # AF_INET6, low byte
    bytes[unsafe_offset=1] = UInt8(0)
    assert_equal(Int(any.addr.sin6_family), 10)
    var len_p = any.len_unsafe_ptr()
    assert_equal(Int(len_p), Int(Pointer(to=any.len)))
    len_p[] = 28
    assert_equal(Int(any.addr_len()), 28)


def test_set_len_clamps_to_the_storage() raises:
    """A kernel-reported length beyond 28 bytes is clamped, not trusted."""
    var any = SocketAddrStorAny()
    any.set_len(16)
    assert_equal(Int(any.addr_len()), 16)
    any.set_len(110)
    assert_equal(Int(any.addr_len()), size_of[sockaddr_in6]())
    any.set_len(0)
    assert_equal(Int(any.addr_len()), 0)


def test_addr_len_clamps_a_kernel_written_length() raises:
    """A length the kernel wrote through the raw pointer is clamped on read.

    recvfrom/getsockname store the true address length into the in/out
    `socklen_t`, which exceeds the slot when the address was truncated.
    The raw field must keep that value (it is the truncation signal)
    while `addr_len()` and `family()` never let a consumer read past
    the 28-byte slot.
    """
    var any = SocketAddrStorAny()
    any.set_len(28)
    var bytes = any.addr_unsafe_mut_ptr()
    bytes[unsafe_offset=0] = UInt8(2)  # AF_INET, low byte (little-endian)
    bytes[unsafe_offset=1] = UInt8(0)
    var len_p = any.len_unsafe_ptr()
    len_p[] = 110
    assert_equal(Int(any.len), 110, "the raw field keeps the kernel value")
    assert_equal(Int(any.addr_len()), 28, "addr_len clamps to the slot")
    assert_equal(Int(any.addr_len()), size_of[sockaddr_in6]())
    assert_true(any.family() == AddrFamily.INET, "family reads the prefix")


def test_family_reads_the_prefix() raises:
    """`family()` is UNSPEC when empty, else follows the stored bytes."""
    var empty = SocketAddrStorAny()
    assert_true(empty.family() == AddrFamily.UNSPEC)
    var v4 = SocketAddrStorAny(SocketAddrV4(10, 0, 0, 1, port=53).addr_stor())
    assert_true(v4.family() == AddrFamily.INET)
    var v6 = SocketAddrStorAny(
        SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=53).addr_stor()
    )
    assert_true(v6.family() == AddrFamily.INET6)
    # Written by the kernel: family bytes present but length still zero
    # means "no name was written", which is UNSPEC.
    var written = SocketAddrStorAny()
    written.addr.sin6_family = 2
    assert_true(written.family() == AddrFamily.UNSPEC)
    written.set_len(16)
    assert_true(written.family() == AddrFamily.INET)


def main() raises:
    test_default_is_zeroed()
    test_from_v4_storage()
    test_from_v6_storage_round_trips()
    test_copy_keeps_bytes_and_len()
    test_mutable_pointers_alias_the_storage()
    test_set_len_clamps_to_the_storage()
    test_addr_len_clamps_a_kernel_written_length()
    test_family_reads_the_prefix()
    print("PASS: test_addr_any.mojo")
