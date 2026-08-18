"""Tests for Socket.local_addr_v4() and Socket.local_addr_v6().

Binds to port 0 (kernel auto-assigns) and verifies that the returned
address has a non-zero port.

Also tests peer_addr_v4() and peer_addr_v6() by creating a listener,
connecting a client, and verifying the peer address on the accepted
connection.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.sys.info import size_of
from std.testing import assert_true, assert_equal

from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrV6
from boucle.net.options import Backlog
from boucle.socle.linux.raw import (
    sockaddr_in, sockaddr_in6, socklen_t, AF_INET, AF_INET6,
)
from boucle.socle.linux.raw.utils import _to_be


def test_local_addr_v4() raises:
    """Bind a TCP/IPv4 socket to 127.0.0.1:0, verify port > 0."""
    var s = Socket.tcp_v4()
    s.bind(SocketAddrV4(127, 0, 0, 1, port=0))

    var local = s.local_addr_v4()
    # Port is stored in network byte order — swap to host order.
    var port = _to_be[DType.uint16, 1](local.addr.sin_port)
    assert_true(Int(port) > 0, "auto-assigned port should be > 0")

    # Family should be AF_INET.
    assert_equal(Int(local.addr.sin_family), AF_INET, "family should be AF_INET")

    s.close()
    print("PASS: local_addr_v4()")


def test_local_addr_v6() raises:
    """Bind a TCP/IPv6 socket to [::1]:0, verify port > 0."""
    var s = Socket.tcp_v6()
    s.set_v6only(True)
    s.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=0))

    var local = s.local_addr_v6()
    var port = _to_be[DType.uint16, 1](local.addr.sin6_port)
    assert_true(Int(port) > 0, "auto-assigned port should be > 0")

    assert_equal(Int(local.addr.sin6_family), AF_INET6, "family should be AF_INET6")

    s.close()
    print("PASS: local_addr_v6()")


def test_peer_addr_v4() raises:
    """Connect TCP/IPv4 to a local listener, verify peer_addr_v4()."""
    # Create listener
    var listener = Socket.tcp_v4()
    listener.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    listener.listen(Backlog(1))

    # Get the assigned port
    var local = listener.local_addr_v4()
    var port = _to_be[DType.uint16, 1](local.addr.sin_port)

    # Connect a blocking client to the listener
    var client = Socket.tcp_connect(SocketAddrV4(127, 0, 0, 1, port=port))

    # Accept on listener (non-blocking, but connection is already pending)
    var acc_addr = sockaddr_in()
    var acc_len = socklen_t(size_of[sockaddr_in]())
    var acc_p = Pointer(to=acc_addr)
    var acc_len_p = Pointer(to=acc_len)
    var accept_fd = external_call["accept", Int32](
        listener._handle._raw, acc_p, acc_len_p,
    )
    if accept_fd < 0:
        client.close()
        raise String("accept failed")

    # Wrap accepted socket
    var peer = Socket(OwnedHandle(raw=accept_fd))
    var peer_addr = peer.peer_addr_v4()
    var peer_port = _to_be[DType.uint16, 1](peer_addr.addr.sin_port)
    assert_true(Int(peer_port) > 0, "peer port should be > 0")
    assert_equal(Int(peer_addr.addr.sin_family), AF_INET, "family should be AF_INET")

    # Verify the peer IP is 127.0.0.1
    var ip_p = Pointer(to=peer_addr.addr.sin_addr_s_addr).unsafe_bitcast[UInt8]()
    assert_equal(Int(ip_p[unsafe_offset=0]), 127, "peer IP byte 0")
    assert_equal(Int(ip_p[unsafe_offset=1]), 0, "peer IP byte 1")
    assert_equal(Int(ip_p[unsafe_offset=2]), 0, "peer IP byte 2")
    assert_equal(Int(ip_p[unsafe_offset=3]), 1, "peer IP byte 3")

    client.close()
    peer.close()
    listener.close()
    print("PASS: peer_addr_v4()")


def test_peer_addr_v6() raises:
    """Connect TCP/IPv6 to a local listener, verify peer_addr_v6()."""
    # Create listener
    var listener = Socket.tcp_v6()
    listener.set_v6only(True)
    listener.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=0))
    listener.listen(Backlog(1))

    # Get the assigned port
    var local = listener.local_addr_v6()
    var port = _to_be[DType.uint16, 1](local.addr.sin6_port)

    # Connect a blocking client to the listener
    var client = Socket.tcp_connect(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=port))

    # Accept on listener (non-blocking, but connection is already pending)
    var acc_addr = sockaddr_in6()
    var acc_len = socklen_t(size_of[sockaddr_in6]())
    var acc_p = Pointer(to=acc_addr)
    var acc_len_p = Pointer(to=acc_len)
    var accept_fd = external_call["accept", Int32](
        listener._handle._raw, acc_p, acc_len_p,
    )
    if accept_fd < 0:
        client.close()
        raise String("accept failed")

    # Wrap accepted socket
    var peer = Socket(OwnedHandle(raw=accept_fd))
    var peer_addr = peer.peer_addr_v6()
    var peer_port = _to_be[DType.uint16, 1](peer_addr.addr.sin6_port)
    assert_true(Int(peer_port) > 0, "peer port should be > 0")
    assert_equal(Int(peer_addr.addr.sin6_family), AF_INET6, "family should be AF_INET6")

    # Verify the peer IP is ::1
    # sin6_addr starts at offset 8 in sockaddr_in6; last byte should be 1
    var addr_p = Pointer(to=peer_addr.addr).unsafe_bitcast[UInt8]()
    # Bytes 8..23 are the 16-byte IPv6 address; ::1 means bytes 8..22 = 0, byte 23 = 1
    assert_equal(Int(addr_p[unsafe_offset=23]), 1, "peer IPv6 addr last byte should be 1")
    # Verify leading bytes are zero (spot check first and middle)
    assert_equal(Int(addr_p[unsafe_offset=8]), 0, "peer IPv6 addr byte 0 should be 0")
    assert_equal(Int(addr_p[unsafe_offset=15]), 0, "peer IPv6 addr byte 7 should be 0")

    client.close()
    peer.close()
    listener.close()
    print("PASS: peer_addr_v6()")


def main() raises:
    test_local_addr_v4()
    test_local_addr_v6()
    test_peer_addr_v4()
    test_peer_addr_v6()
