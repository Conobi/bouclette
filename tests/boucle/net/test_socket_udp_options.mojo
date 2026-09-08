"""`Socket` UDP offload and buffer-size setters, read back through raw getsockopt.

Every assertion reads the option through `getsockopt(2)` directly, so a
setter that writes the wrong level or option id fails here even if the
kernel accepted the call.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.socle.linux.raw import (
    SOL_SOCKET,
    SOL_UDP,
    SO_RCVBUF,
    SO_SNDBUF,
    UDP_GRO,
    UDP_SEGMENT,
    EINVAL,
    ENOPROTOOPT,
    EOPNOTSUPP,
)


def _getsockopt_int(fd: Int32, level: Int32, optname: Int32) raises -> Int32:
    """Raw `getsockopt(2)` of a 4-byte option, bypassing `Socket`."""
    var val = Int32(-1)
    var optlen = UInt32(4)
    var v_p = Pointer(to=val)
    var l_p = Pointer(to=optlen)
    var res = external_call["getsockopt", Int32](
        fd, level, optname, v_p, l_p,
    )
    if res < 0:
        raise String("getsockopt failed: ", Int(res))
    return val


def _read(ref s: Socket, level: Int32, optname: Int32) raises -> Int32:
    """Read an integer option, keeping `s` alive through the syscall.

    `s.raw()` is a plain fd untied to `s`; an inline `s.raw()` argument
    at `s`'s last use lets ASAP destruction close the socket before the
    syscall runs. The `ref` parameter keeps `s` alive for the whole call.
    """
    return _getsockopt_int(s.raw(), level, optname)


def test_gro_on_udp_v4_reads_back() raises:
    """`UDP_GRO` is 0 on a fresh socket, 1 after `set_gro()`, 0 after `set_gro(False)`."""
    var s = Socket.udp_v4()
    assert_equal(_read(s, Int32(SOL_UDP), Int32(UDP_GRO)), Int32(0))
    s.set_gro()
    assert_equal(_read(s, Int32(SOL_UDP), Int32(UDP_GRO)), Int32(1))
    s.set_gro(False)
    assert_equal(_read(s, Int32(SOL_UDP), Int32(UDP_GRO)), Int32(0))


def test_gro_on_tcp_is_enoprotoopt() raises:
    """TCP has no `SOL_UDP` level; the kernel answers ENOPROTOOPT."""
    var s = Socket.tcp_v4()
    var caught = False
    try:
        s.set_gro()
    except e:
        caught = e.errno_value() == ENOPROTOOPT
    assert_true(caught, "TCP: set_gro must raise ENOPROTOOPT")


def test_gso_segment_size_reads_back() raises:
    """`UDP_SEGMENT` reads back 1200 after `set_gso_segment_size(1200)`; 0 disables."""
    var s = Socket.udp_v4()
    assert_equal(_read(s, Int32(SOL_UDP), Int32(UDP_SEGMENT)), Int32(0))
    s.set_gso_segment_size(1200)
    assert_equal(_read(s, Int32(SOL_UDP), Int32(UDP_SEGMENT)), Int32(1200))
    s.set_gso_segment_size(0)
    assert_equal(_read(s, Int32(SOL_UDP), Int32(UDP_SEGMENT)), Int32(0))


def test_gso_on_tcp_is_enoprotoopt() raises:
    """`set_gso_segment_size` on TCP raises the kernel's ENOPROTOOPT."""
    var s = Socket.tcp_v4()
    var caught = False
    try:
        s.set_gso_segment_size(1200)
    except e:
        caught = e.errno_value() == ENOPROTOOPT
    assert_true(caught, "TCP: set_gso_segment_size must raise ENOPROTOOPT")


def test_gro_on_unix_socket_is_eopnotsupp() raises:
    """AF_UNIX has no setsockopt for non-SOL_SOCKET levels; the kernel answers EOPNOTSUPP."""
    var fds = InlineArray[Int32, 2](fill=Int32(0))
    var fds_p = Pointer(to=fds)
    var res = external_call["socketpair", Int32](
        Int32(1), Int32(2 | 2048 | 524288), Int32(0), fds_p
    )
    assert_true(res == 0, "socketpair")
    var a = Socket(OwnedHandle(raw=fds[0]))
    var b = Socket(OwnedHandle(raw=fds[1]))
    var caught = False
    try:
        a.set_gro()
    except e:
        caught = e.errno_value() == EOPNOTSUPP
    assert_true(caught, "AF_UNIX: set_gro must raise EOPNOTSUPP")
    a.close()
    b.close()


def test_recv_buffer_size_roundtrip() raises:
    """`set_recv_buffer_size(65536)` reads back 131072: the kernel doubles it.

    65536 sits below the 212992 `net.core.rmem_max` default, so the
    doubled value is not clamped by the sysctl cap.
    """
    var s = Socket.udp_v4()
    s.set_recv_buffer_size(65536)
    assert_equal(s.recv_buffer_size(), 131072)
    assert_equal(_read(s, Int32(SOL_SOCKET), Int32(SO_RCVBUF)), Int32(131072))


def test_send_buffer_size_roundtrip() raises:
    """`set_send_buffer_size(65536)` reads back 131072 under the `wmem_max` default."""
    var s = Socket.udp_v4()
    s.set_send_buffer_size(65536)
    assert_equal(s.send_buffer_size(), 131072)
    assert_equal(_read(s, Int32(SOL_SOCKET), Int32(SO_SNDBUF)), Int32(131072))


def test_buffer_size_out_of_range_is_einval_without_syscall() raises:
    """Values outside 0..Int32.MAX raise EINVAL and leave the option untouched.

    The kernel would read -1 as a huge unsigned value and clamp it to
    the sysctl cap, changing the option; an unchanged read-back proves
    the call never reached the kernel.
    """
    var s = Socket.udp_v4()
    var rcv_before = _read(s, Int32(SOL_SOCKET), Int32(SO_RCVBUF))
    var snd_before = _read(s, Int32(SOL_SOCKET), Int32(SO_SNDBUF))

    var caught = False
    try:
        s.set_recv_buffer_size(-1)
    except e:
        caught = e.errno_value() == EINVAL
    assert_true(caught, "set_recv_buffer_size(-1) must raise EINVAL")

    caught = False
    try:
        s.set_recv_buffer_size(Int(Int32.MAX) + 1)
    except e:
        caught = e.errno_value() == EINVAL
    assert_true(caught, "set_recv_buffer_size(Int32.MAX + 1) must raise EINVAL")

    caught = False
    try:
        s.set_send_buffer_size(-1)
    except e:
        caught = e.errno_value() == EINVAL
    assert_true(caught, "set_send_buffer_size(-1) must raise EINVAL")

    caught = False
    try:
        s.set_send_buffer_size(Int(Int32.MAX) + 1)
    except e:
        caught = e.errno_value() == EINVAL
    assert_true(caught, "set_send_buffer_size(Int32.MAX + 1) must raise EINVAL")

    assert_equal(_read(s, Int32(SOL_SOCKET), Int32(SO_RCVBUF)), rcv_before)
    assert_equal(_read(s, Int32(SOL_SOCKET), Int32(SO_SNDBUF)), snd_before)


def test_zero_buffer_size_is_clamped_to_the_floor() raises:
    """`set_recv_buffer_size(0)` is accepted; the kernel clamps to `SOCK_MIN_RCVBUF`, above 0."""
    var s = Socket.udp_v4()
    s.set_recv_buffer_size(0)
    assert_true(s.recv_buffer_size() > 0, "kernel floor applies")
    s.set_send_buffer_size(0)
    assert_true(s.send_buffer_size() > 0, "kernel floor applies")


def test_buffer_size_on_unix_socket_works() raises:
    """`SO_RCVBUF` is a `SOL_SOCKET` option, so it applies to AF_UNIX too."""
    var fds = InlineArray[Int32, 2](fill=Int32(0))
    var fds_p = Pointer(to=fds)
    var res = external_call["socketpair", Int32](
        Int32(1), Int32(2 | 2048 | 524288), Int32(0), fds_p
    )
    assert_true(res == 0, "socketpair")
    var a = Socket(OwnedHandle(raw=fds[0]))
    var b = Socket(OwnedHandle(raw=fds[1]))
    a.set_recv_buffer_size(65536)
    assert_equal(a.recv_buffer_size(), 131072)
    a.close()
    b.close()


def main() raises:
    test_gro_on_udp_v4_reads_back()
    test_gro_on_tcp_is_enoprotoopt()
    test_gso_segment_size_reads_back()
    test_gso_on_tcp_is_enoprotoopt()
    test_gro_on_unix_socket_is_eopnotsupp()
    test_recv_buffer_size_roundtrip()
    test_send_buffer_size_roundtrip()
    test_buffer_size_out_of_range_is_einval_without_syscall()
    test_zero_buffer_size_is_clamped_to_the_floor()
    test_buffer_size_on_unix_socket_works()
    print("PASS: test_socket_udp_options.mojo")
