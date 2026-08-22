from boucle.socle.linux.raw.net import (
    sockaddr_in, sockaddr_in6, in_addr, in6_addr,
    iovec, msghdr,
    cmsghdr, in_pktinfo, in6_pktinfo,
    AF_INET, AF_INET6, SOCK_STREAM, SOCK_DGRAM,
    IPPROTO_TCP, IPPROTO_UDP,
)
from boucle.socle.linux.raw.epoll import epoll_event
from boucle.socle.linux.raw.io_uring import (
    io_uring_buf, io_sqring_offsets, io_cqring_offsets,
)
from std.testing import assert_equal
from std.sys.info import size_of


def test_net_structs() raises:
    assert_equal(size_of[in_addr](), 4)
    assert_equal(size_of[sockaddr_in](), 16)
    assert_equal(size_of[in6_addr](), 16)
    assert_equal(size_of[sockaddr_in6](), 28)
    assert_equal(size_of[iovec](), 16)
    assert_equal(size_of[msghdr](), 56)

    # Golden UAPI sizes -- guard against silent struct-padding regressions.
    # epoll_event is __packed__ in the kernel UAPI on x86_64 (12 bytes, not 16).
    assert_equal(size_of[epoll_event](), 12)
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


def main() raises:
    test_net_structs()
    print("PASS: test_net_structs.mojo")
