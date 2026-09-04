"""Dropping a Future before run() must hand the in-flight state to the loop.

Every WatchLoop future owns heap state whose address the driver holds
until the completion is delivered. If the caller drops the future first,
the completion must still land in live memory, and any resource it
produces (an accepted fd) must still be released.

socketpair(2), dup(2) and fcntl(2) are called directly: boucle.net does
not wrap them, and the fd-leak check needs raw descriptor numbers.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.handle import OwnedHandle
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.net.socket import Socket
from boucle.socle.linux.errno import get_errno
from boucle.socle.linux.raw import F_GETFL
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
    """Create a non-blocking TCP v4 listener on 127.0.0.1 with an ephemeral port.

    Returns:
        The listening socket.
    """
    var server = Socket.tcp_v4()
    server.set_reuse_addr()
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)
    return server^


def _make_blocking_client(port: UInt16) raises -> Socket:
    """Create a blocking TCP client already connected to 127.0.0.1:port.

    Args:
        port: The listener's port, in host byte order.

    Returns:
        The connected client socket.
    """
    return Socket.tcp_connect(SocketAddrV4(127, 0, 0, 1, port=port))


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

    var recv_f = loop.recv(reader, List[UInt8](length=16, fill=0))
    _ = recv_f^  # Dropped while the recv is still in flight.

    var msg = String("data")
    var sent = writer.send(msg.as_bytes())
    assert_equal(sent, 4, "the peer should accept the whole message")

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

    var msg = List[UInt8](length=4, fill=100)
    var send_f = loop.send(writer, msg^)
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
    var port = server.local_addr_v4().port
    var client = Socket.tcp_v4()
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
    var port = server.local_addr_v4().port
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
    var port = server.local_addr_v4().port
    var client = Socket.tcp_v4()
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
