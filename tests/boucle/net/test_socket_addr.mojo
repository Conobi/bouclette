"""Tests for Socket.local_addr_v4() and Socket.local_addr_v6().

Binds to port 0 (kernel auto-assigns) and verifies that the returned
address has a non-zero port.

NOTE: Uses raw external_call for bind to work around a Mojo 1.0.0
cross-package inlining bug that corrupts TRP arguments in _bind.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_true, assert_equal

from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.socle.linux.raw import AF_INET, AF_INET6
from boucle.socle.linux.raw.utils import _to_be


def _raw_bind_v4(fd: Int32) raises:
    """Bind fd to 127.0.0.1:0 using raw external_call."""
    var sa = InlineArray[UInt8, 16](fill=0)
    sa[0] = 2  # AF_INET
    sa[4] = 127
    sa[5] = 0
    sa[6] = 0
    sa[7] = 1
    var sa_p = Pointer(to=sa)
    var res = external_call["bind", Int32](fd, sa_p, Int32(16))
    if res < 0:
        raise String("bind failed")


def _raw_bind_v6(fd: Int32) raises:
    """Bind fd to [::1]:0 using raw external_call."""
    # sockaddr_in6: family(2) + port(2) + flowinfo(4) + addr(16) + scope(4) = 28
    var sa = InlineArray[UInt8, 28](fill=0)
    sa[0] = 10  # AF_INET6
    # port = 0 (bytes 2-3)
    # flowinfo = 0 (bytes 4-7)
    # addr = ::1 → last byte is 1, at offset 8+15=23
    sa[23] = 1
    # scope_id = 0 (bytes 24-27)
    var sa_p = Pointer(to=sa)
    var res = external_call["bind", Int32](fd, sa_p, Int32(28))
    if res < 0:
        raise String("bind failed")


def test_local_addr_v4() raises:
    """Bind a TCP/IPv4 socket to 127.0.0.1:0, verify port > 0."""
    var s = Socket.tcp_v4()
    _raw_bind_v4(s._handle._raw)

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
    # Set IPV6_V6ONLY before bind
    var v6only_val = Int32(1)
    var v6only_p = Pointer(to=v6only_val)
    _ = external_call["setsockopt", Int32](
        s._handle._raw, Int32(41), Int32(26), v6only_p, UInt32(4),
    )  # SOL_IPV6=41, IPV6_V6ONLY=26
    _raw_bind_v6(s._handle._raw)

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
    _raw_bind_v4(listener._handle._raw)

    # Raw listen
    var listen_res = external_call["listen", Int32](listener._handle._raw, Int32(1))
    if listen_res < 0:
        raise String("listen failed")

    # Get the assigned port
    var local = listener.local_addr_v4()
    var port = local.addr.sin_port  # network byte order

    # Connect a client to the listener
    var client_fd = external_call["socket", Int32](
        Int32(2), Int32(1), Int32(6),  # AF_INET, SOCK_STREAM, IPPROTO_TCP
    )
    if client_fd < 0:
        raise String("socket failed")
    var sa = InlineArray[UInt8, 16](fill=0)
    sa[0] = 2  # AF_INET
    # Port in network byte order (copy directly)
    var port_p = Pointer(to=port).unsafe_bitcast[UInt8]()
    sa[2] = port_p[unsafe_offset=0]
    sa[3] = port_p[unsafe_offset=1]
    sa[4] = 127
    sa[5] = 0
    sa[6] = 0
    sa[7] = 1
    var sa_p = Pointer(to=sa)
    var conn_res = external_call["connect", Int32](client_fd, sa_p, Int32(16))
    if conn_res < 0:
        _ = external_call["close", Int32](client_fd)
        raise String("connect failed")

    # Accept on listener (non-blocking, but connection is already pending)
    var acc_buf = InlineArray[UInt8, 16](fill=0)
    var acc_len = Int32(16)
    var acc_buf_p = Pointer(to=acc_buf)
    var acc_len_p = Pointer(to=acc_len)
    var accept_fd = external_call["accept", Int32](
        listener._handle._raw, acc_buf_p, acc_len_p,
    )
    if accept_fd < 0:
        _ = external_call["close", Int32](client_fd)
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

    _ = external_call["close", Int32](client_fd)
    peer.close()
    listener.close()
    print("PASS: peer_addr_v4()")


def main() raises:
    test_local_addr_v4()
    test_local_addr_v6()
    test_peer_addr_v4()
