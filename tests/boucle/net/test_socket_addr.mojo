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
    sockaddr_in, sockaddr_in6, socklen_t,
)


def test_local_addr_v4() raises:
    """Bind a TCP/IPv4 socket to 127.0.0.1:0, verify port > 0."""
    var s = Socket.tcp_v4()
    s.bind(SocketAddrV4(127, 0, 0, 1, port=0))

    var local = s.local_addr_v4()
    assert_true(Int(local.port) > 0, "auto-assigned port should be > 0")

    s.close()
    print("PASS: local_addr_v4()")


def test_local_addr_v6() raises:
    """Bind a TCP/IPv6 socket to [::1]:0, verify port > 0."""
    var s = Socket.tcp_v6()
    s.set_v6only(True)
    s.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=0))

    var local = s.local_addr_v6()
    assert_true(Int(local.port) > 0, "auto-assigned port should be > 0")

    s.close()
    print("PASS: local_addr_v6()")


def test_peer_addr_v4() raises:
    """Connect TCP/IPv4 to a local listener, verify peer_addr_v4()."""
    var listener = Socket.tcp_v4()
    listener.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    listener.listen(Backlog(1))

    var port = listener.local_addr_v4().port

    var client = Socket.tcp_connect(SocketAddrV4(127, 0, 0, 1, port=port))

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

    var peer = Socket(OwnedHandle(raw=accept_fd))
    var peer_addr = peer.peer_addr_v4()
    assert_true(Int(peer_addr.port) > 0, "peer port should be > 0")

    assert_equal(Int(peer_addr.ip.octets[0]), 127, "peer IP byte 0")
    assert_equal(Int(peer_addr.ip.octets[1]), 0, "peer IP byte 1")
    assert_equal(Int(peer_addr.ip.octets[2]), 0, "peer IP byte 2")
    assert_equal(Int(peer_addr.ip.octets[3]), 1, "peer IP byte 3")

    client.close()
    peer.close()
    listener.close()
    print("PASS: peer_addr_v4()")


def test_peer_addr_v6() raises:
    """Connect TCP/IPv6 to a local listener, verify peer_addr_v6()."""
    var listener = Socket.tcp_v6()
    listener.set_v6only(True)
    listener.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=0))
    listener.listen(Backlog(1))

    var port = listener.local_addr_v6().port

    var client = Socket.tcp_connect(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=port))

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

    var peer = Socket(OwnedHandle(raw=accept_fd))
    var peer_addr = peer.peer_addr_v6()
    assert_true(Int(peer_addr.port) > 0, "peer port should be > 0")

    # ::1 means segments 0..6 = 0, segment 7 = 1
    assert_equal(Int(peer_addr.ip.segments[7]), 1, "peer IPv6 last segment should be 1")
    assert_equal(Int(peer_addr.ip.segments[0]), 0, "peer IPv6 first segment should be 0")
    assert_equal(Int(peer_addr.ip.segments[3]), 0, "peer IPv6 mid segment should be 0")

    client.close()
    peer.close()
    listener.close()
    print("PASS: peer_addr_v6()")


def main() raises:
    test_local_addr_v4()
    test_local_addr_v6()
    test_peer_addr_v4()
    test_peer_addr_v6()
