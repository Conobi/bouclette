from boucle.socle.linux.raw.net import (
    sockaddr_in, sockaddr_in6, in_addr, in6_addr,
    iovec, msghdr,
    cmsghdr, in_pktinfo, in6_pktinfo,
    AF_INET, AF_INET6, SOCK_STREAM, SOCK_DGRAM,
    IPPROTO_TCP, IPPROTO_UDP,
    IP_TOS, IP_RECVTOS, IPV6_TCLASS, IPV6_RECVTCLASS,
    SOL_IP, SOL_IPV6, MSG_TRUNC, MSG_CTRUNC,
)
from boucle.socle.linux.raw.epoll import epoll_event
from boucle.socle.linux.raw.io_uring import (
    io_uring_buf, io_sqring_offsets, io_cqring_offsets,
)
from boucle.socle.linux.raw.utils import _pick_int
from std.testing import assert_equal
from std.sys.info import size_of
from std.memory import Pointer


def test_net_structs() raises:
    assert_equal(size_of[in_addr](), 4)
    assert_equal(size_of[sockaddr_in](), 16)
    assert_equal(size_of[in6_addr](), 16)
    assert_equal(size_of[sockaddr_in6](), 28)
    assert_equal(size_of[iovec](), 16)
    assert_equal(size_of[msghdr](), 56)

    # Golden UAPI sizes -- guard against silent struct-padding regressions.
    # epoll_event is __packed__ on x86_64 (12 bytes); natural alignment on aarch64 (16 bytes).
    assert_equal(size_of[epoll_event](), _pick_int[12, 16]())
    assert_equal(size_of[io_uring_buf](), 16)
    assert_equal(size_of[io_sqring_offsets](), 40)
    assert_equal(size_of[io_cqring_offsets](), 40)
    assert_equal(size_of[cmsghdr](), 16)
    assert_equal(size_of[in_pktinfo](), 12)
    assert_equal(size_of[in6_pktinfo](), 20)

    var sa4 = sockaddr_in()
    assert_equal(Int(sa4.sin_family), 0)
    assert_equal(Int(sa4.sin_port), 0)

    var sa6 = sockaddr_in6()
    assert_equal(Int(sa6.sin6_family), 0)
    assert_equal(Int(sa6.sin6_scope_id), 0)

    assert_equal(AF_INET, 2)
    assert_equal(AF_INET6, 10)
    assert_equal(SOCK_STREAM, 1)
    assert_equal(SOCK_DGRAM, 2)
    assert_equal(IPPROTO_TCP, 6)
    assert_equal(IPPROTO_UDP, 17)


def test_tos_constants() raises:
    """The IP_TOS/TCLASS option ids and the levels they are set at."""
    assert_equal(IP_TOS, 1)
    assert_equal(IP_RECVTOS, 13)
    assert_equal(IPV6_TCLASS, 67)
    assert_equal(IPV6_RECVTCLASS, 66)
    assert_equal(SOL_IP, 0)
    assert_equal(SOL_IPV6, 41)
    assert_equal(MSG_TRUNC, 32)
    assert_equal(MSG_CTRUNC, 8)


def test_cmsghdr_field_offsets() raises:
    """Cmsg_len sits at 0 (8 bytes), cmsg_level at 8, cmsg_type at 12.

    The control walker and `Message.set_ecn` read and write records by
    these offsets, so a padding change here must fail loudly.
    """
    var hdr = cmsghdr()
    hdr.cmsg_len = 17
    hdr.cmsg_level = 41
    hdr.cmsg_type = 67
    var base = Int(Pointer(to=hdr))
    assert_equal(Int(Pointer(to=hdr.cmsg_len)) - base, 0)
    assert_equal(Int(Pointer(to=hdr.cmsg_level)) - base, 8)
    assert_equal(Int(Pointer(to=hdr.cmsg_type)) - base, 12)
    var bytes = Pointer(to=hdr).unsafe_bitcast[UInt8]()
    # Byte-level checks assume little-endian, true for x86_64 and aarch64 Linux.
    assert_equal(Int(bytes[unsafe_offset=0]), 17)
    assert_equal(Int(bytes[unsafe_offset=8]), 41)
    assert_equal(Int(bytes[unsafe_offset=12]), 67)


def main() raises:
    test_net_structs()
    test_tos_constants()
    test_cmsghdr_field_offsets()
    print("PASS: test_net_structs.mojo")
