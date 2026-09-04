"""Every failing Socket operation must raise an IOError, not a bare String.

Each test catches the error and calls an `IOError` method on it: that only
compiles if the operation really is declared `raises IOError`.
"""

from std.testing import assert_true, assert_equal

from boucle.error import IOError
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Shutdown
from boucle.socle.linux.raw import EBADF, EINPROGRESS, ENOTCONN, EPIPE


def test_recv_on_unconnected_socket_raises_ioerror() raises:
    var s = Socket.tcp_v4()
    var buf = InlineArray[UInt8, 8](fill=0)
    var caught = False
    try:
        _ = s.recv(Span(buf))
    except e:
        caught = True
        assert_equal(e, IOError.from_errno(ENOTCONN))
        assert_true(e.is_connection_refused() == False)
    assert_true(caught, "recv on an unconnected socket must raise")


def test_send_on_unconnected_socket_raises_ioerror() raises:
    var s = Socket.tcp_v4()
    var data = InlineArray[UInt8, 3](fill=65)
    var caught = False
    try:
        _ = s.send(Span(data))
    except e:
        caught = True
        # Linux reports the broken pipe rather than ENOTCONN because
        # MSG_NOSIGNAL suppresses the SIGPIPE that would normally fire.
        assert_true(e.is_broken_pipe(), String("expected EPIPE, got ", e))
        assert_equal(e.errno_value(), EPIPE)
    assert_true(caught, "send on an unconnected socket must raise")


def test_peer_addr_on_unconnected_socket_raises_ioerror() raises:
    var s = Socket.tcp_v4()
    var caught = False
    try:
        _ = s.peer_addr_v4()
    except e:
        caught = True
        assert_equal(e.errno_value(), ENOTCONN)
    assert_true(caught, "peer_addr_v4 on an unconnected socket must raise")


def test_shutdown_on_unconnected_socket_raises_ioerror() raises:
    var s = Socket.tcp_v4()
    var caught = False
    try:
        s.shutdown(Shutdown.BOTH)
    except e:
        caught = True
        assert_equal(e.errno_value(), ENOTCONN)
    assert_true(caught, "shutdown on an unconnected socket must raise")


def test_closed_socket_raises_ebadf() raises:
    var s = Socket.tcp_v4()
    s.close()
    var caught = False
    try:
        _ = s.raw()
    except e:
        caught = True
        assert_equal(e.errno_value(), EBADF)
    assert_true(caught, "raw() on a closed socket must raise EBADF")

    var buf = InlineArray[UInt8, 8](fill=0)
    var recv_caught = False
    try:
        _ = s.recv(Span(buf))
    except e:
        recv_caught = True
        assert_equal(e.errno_value(), EBADF)
    assert_true(recv_caught, "recv on a closed socket must raise EBADF")


def test_nonblocking_connect_reports_in_progress() raises:
    """Sockets are NONBLOCK, so connect starts the handshake and returns."""
    var s = Socket.tcp_v4()
    # 203.0.113.0/24 is TEST-NET-3: reserved for documentation, never routed,
    # so the handshake cannot complete inside the syscall.
    var addr = SocketAddrV4(203, 0, 113, 1, port=9)
    var caught = False
    try:
        s.connect(addr)
    except e:
        caught = True
        assert_true(
            e.is_in_progress(),
            String("expected EINPROGRESS, got ", e),
        )
        assert_equal(e.errno_value(), EINPROGRESS)
    assert_true(caught, "a non-blocking connect must report EINPROGRESS")


def main() raises:
    test_recv_on_unconnected_socket_raises_ioerror()
    test_send_on_unconnected_socket_raises_ioerror()
    test_peer_addr_on_unconnected_socket_raises_ioerror()
    test_shutdown_on_unconnected_socket_raises_ioerror()
    test_closed_socket_raises_ebadf()
    test_nonblocking_connect_reports_in_progress()
    print("PASS: test_socket_raises.mojo")
