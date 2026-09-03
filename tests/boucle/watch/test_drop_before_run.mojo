"""Dropping a Future before run() must hand the in-flight state to the loop.

Every WatchLoop future owns heap state whose address the driver holds
until the completion is delivered. If the caller drops the future first,
the completion must still land in live memory, and any resource it
produces (an accepted fd) must still be released.

Uses direct syscalls for socket setup due to a Mojo 1.0.0 compiler bug
affecting Socket.bind() through parametric inlining.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.sys.info import size_of
from std.testing import assert_equal, assert_true

from boucle.handle import OwnedHandle
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.socle.linux.errno import get_errno
from boucle.socle.linux.raw import F_GETFL, sockaddr_in, socklen_t
from boucle.watch import WatchLoop


def _make_socketpair() raises -> Tuple[Int32, Int32]:
    """Create a connected, non-blocking AF_UNIX SOCK_STREAM socketpair.

    Returns:
        The two raw fds; the caller wraps them in Socket.
    """
    var fds = InlineArray[Int32, 2](fill=Int32(0))
    var fds_p = Pointer(to=fds)
    var res = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1 | 2048 | 524288),  # SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
        Int32(0),
        fds_p,
    )
    if res < 0:
        raise String("socketpair failed: errno ", Int(get_errno()))
    return (fds[0], fds[1])


def _make_tcp_listener() raises -> Socket:
    """Create a non-blocking TCP v4 listener on 127.0.0.1 with an ephemeral port."""
    var fd = external_call["socket", Int32](
        Int32(2), Int32(1 | 2048 | 524288), Int32(6)
    )
    if fd < 0:
        raise String("socket failed: errno ", Int(get_errno()))
    var one = Int32(1)
    var one_p = Pointer(to=one)
    _ = external_call["setsockopt", Int32](
        fd, Int32(1), Int32(2), one_p, UInt32(4)
    )
    var addr = sockaddr_in()
    addr.sin_family = UInt16(2)
    addr.sin_port = UInt16(0)
    addr.sin_addr_s_addr = UInt32(0x0100007F)
    var addr_p = Pointer(to=addr)
    var res = external_call["bind", Int32](
        fd, addr_p, UInt32(size_of[sockaddr_in]())
    )
    if res < 0:
        _ = external_call["close", Int32](fd)
        raise String("bind failed: errno ", Int(get_errno()))
    res = external_call["listen", Int32](fd, Int32(128))
    if res < 0:
        _ = external_call["close", Int32](fd)
        raise String("listen failed: errno ", Int(get_errno()))
    return Socket(OwnedHandle(raw=fd))


def _get_port(ref server: Socket) raises -> UInt16:
    """Return the ephemeral port assigned to a bound socket."""
    var addr = sockaddr_in()
    var addrlen = socklen_t(size_of[sockaddr_in]())
    var addr_p = Pointer(to=addr)
    var len_p = Pointer(to=addrlen)
    var fd = server.raw()
    var res = external_call["getsockname", Int32](fd, addr_p, len_p)
    if res < 0:
        raise String("getsockname failed: errno ", Int(get_errno()))
    var be = addr.sin_port
    return ((be << 8) | (be >> 8)) & UInt16(0xFFFF)


def _make_blocking_client(port: UInt16) raises -> Socket:
    """Create a blocking TCP client already connected to 127.0.0.1:port."""
    var fd = external_call["socket", Int32](
        Int32(2), Int32(1 | 524288), Int32(6)
    )
    if fd < 0:
        raise String("socket failed: errno ", Int(get_errno()))
    var addr = sockaddr_in()
    addr.sin_family = UInt16(2)
    addr.sin_port = ((port << 8) | (port >> 8)) & UInt16(0xFFFF)
    addr.sin_addr_s_addr = UInt32(0x0100007F)
    var addr_p = Pointer(to=addr)
    var res = external_call["connect", Int32](
        fd, addr_p, UInt32(size_of[sockaddr_in]())
    )
    if res < 0:
        _ = external_call["close", Int32](fd)
        raise String("connect failed: errno ", Int(get_errno()))
    return Socket(OwnedHandle(raw=fd))


def _make_client_socket() raises -> Socket:
    """Create a non-blocking, unconnected TCP client socket."""
    var fd = external_call["socket", Int32](
        Int32(2), Int32(1 | 2048 | 524288), Int32(6)
    )
    if fd < 0:
        raise String("socket failed: errno ", Int(get_errno()))
    return Socket(OwnedHandle(raw=fd))


def _lowest_free_fd() raises -> Int32:
    """Return the fd number the kernel will hand out next.

    POSIX guarantees dup() and accept() both return the lowest unused
    descriptor, so dup(0)+close predicts the fd an upcoming accept will
    produce, provided nothing else opens an fd in between.
    """
    var probe = external_call["dup", Int32](Int32(0))
    if probe < 0:
        raise String("dup failed: errno ", Int(get_errno()))
    _ = external_call["close", Int32](probe)
    return probe


def _fd_is_open(fd: Int32) -> Bool:
    """Return True if fd refers to an open descriptor (fcntl F_GETFL succeeds)."""
    return external_call["fcntl", Int32](fd, Int32(F_GETFL)) >= 0


def _send_all(fd: Int32, ref data: String) raises:
    """Send the whole string on fd via send(2), raising on short sends."""
    var sent = external_call["send", Int64](
        fd, data.unsafe_ptr(), UInt64(data.byte_length()), Int32(0)
    )
    if Int(sent) != data.byte_length():
        raise String("send failed: errno ", Int(get_errno()))


def _assert_loop_still_usable(mut loop: WatchLoop) raises:
    """A fresh timer on the loop must resolve; proves the loop survived."""
    var timer_f = loop.timeout(1)
    loop.run()
    assert_true(timer_f.result(), "fresh timer should expire after run()")


def test_recv_dropped_before_run_completes_safely() raises:
    """A RecvFuture dropped before run() still completes without corruption."""
    var fds = _make_socketpair()
    var reader = Socket(OwnedHandle(raw=fds[0]))
    var writer = Socket(OwnedHandle(raw=fds[1]))
    var loop = WatchLoop()

    var recv_buf = InlineArray[UInt8, 16](fill=UInt8(0))
    var recv_span = Span[UInt8, MutAnyOrigin](
        unsafe_ptr=Pointer[UInt8, MutAnyOrigin](
            unsafe_from_address=Int(Pointer(to=recv_buf))
        ),
        length=16,
    )
    var recv_f = loop.recv(reader, recv_span)
    _ = recv_f^  # Dropped while the recv is still in flight.

    var msg = String("data")
    _send_all(fds[1], msg)

    loop.run()
    assert_equal(loop._pending, 0, "run() should drain the orphaned recv")
    _assert_loop_still_usable(loop)

    reader.close()
    writer.close()


def test_send_dropped_before_run_completes_safely() raises:
    """A SendFuture dropped before run() still completes without corruption."""
    var fds = _make_socketpair()
    var writer = Socket(OwnedHandle(raw=fds[0]))
    var reader = Socket(OwnedHandle(raw=fds[1]))
    var loop = WatchLoop()

    # The buffer must outlive run(); only the future is dropped early.
    var msg = String("data")
    var send_f = loop.send(writer, msg.as_bytes())
    _ = send_f^  # Dropped while the send is still in flight.

    loop.run()
    assert_equal(loop._pending, 0, "run() should drain the orphaned send")
    _assert_loop_still_usable(loop)

    writer.close()
    reader.close()


def test_timer_dropped_before_run_completes_safely() raises:
    """A TimerFuture dropped before run() still fires without corruption."""
    var loop = WatchLoop()

    var timer_f = loop.timeout(5)
    _ = timer_f^  # Dropped while the timer is still armed.

    loop.run()
    assert_equal(loop._pending, 0, "run() should drain the orphaned timer")
    _assert_loop_still_usable(loop)


def test_connect_dropped_before_run_completes_safely() raises:
    """A ConnectFuture dropped before run() still completes without corruption."""
    var server = _make_tcp_listener()
    var port = _get_port(server)
    var client = _make_client_socket()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)
    var loop = WatchLoop()

    var connect_f = loop.connect(client, target)
    _ = connect_f^  # Dropped while the connect is still in flight.

    loop.run()
    assert_equal(loop._pending, 0, "run() should drain the orphaned connect")
    _assert_loop_still_usable(loop)

    client.close()
    server.close()


def test_accept_dropped_before_run_closes_accepted_fd() raises:
    """An AcceptFuture dropped before run() must not leak the accepted fd.

    The fd the kernel will assign to the accepted socket is predicted
    with dup(0)+close immediately before run(): both dup() and accept()
    return the lowest unused descriptor and nothing else opens an fd in
    between. After run() that number must be closed again (fcntl F_GETFL
    fails with EBADF).
    """
    var server = _make_tcp_listener()
    var port = _get_port(server)
    var client = _make_blocking_client(port)
    var loop = WatchLoop()

    var accept_f = loop.accept(server)
    _ = accept_f^  # Dropped while the accept is still in flight.

    var predicted_fd = _lowest_free_fd()
    loop.run()
    assert_equal(loop._pending, 0, "run() should drain the orphaned accept")
    assert_true(
        not _fd_is_open(predicted_fd),
        String("accepted fd ", predicted_fd, " leaked after drop"),
    )
    _assert_loop_still_usable(loop)

    client.close()
    server.close()


def test_connect_with_timeout_dropped_before_run_completes_safely() raises:
    """A ConnectWithTimeoutFuture dropped before run() still completes.

    The loop tracks the composite until all three completions (connect,
    timeout, cancel) have arrived; after run() it must no longer be
    tracked and the loop must remain usable.
    """
    var server = _make_tcp_listener()
    var port = _get_port(server)
    var client = _make_client_socket()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)
    var loop = WatchLoop()

    var connect_f = loop.connect_with_timeout(client, target, timeout_ms=5000)
    _ = connect_f^  # Dropped while connect and timeout are both in flight.

    loop.run()
    assert_equal(loop._pending, 0, "run() should drain the orphaned composite")
    assert_equal(
        loop.pending_composites(),
        0,
        "orphaned composite should be released once all CQEs arrived",
    )
    _assert_loop_still_usable(loop)

    client.close()
    server.close()


def main() raises:
    test_recv_dropped_before_run_completes_safely()
    print("ok: recv dropped before run")
    test_send_dropped_before_run_completes_safely()
    print("ok: send dropped before run")
    test_timer_dropped_before_run_completes_safely()
    print("ok: timer dropped before run")
    test_connect_dropped_before_run_completes_safely()
    print("ok: connect dropped before run")
    test_accept_dropped_before_run_closes_accepted_fd()
    print("ok: accept dropped before run closes fd")
    test_connect_with_timeout_dropped_before_run_completes_safely()
    print("ok: connect_with_timeout dropped before run")
    print("PASS: test_drop_before_run.mojo")
