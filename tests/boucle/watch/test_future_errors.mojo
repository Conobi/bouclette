"""Tests for Future error paths and edge cases.

Covers the two error shapes a Future can report:

- a syscall failure, raised as an `IOError` carrying the errno, so the
  message names the error (`ENOTCONN (107)`) instead of spelling out a
  number;
- misuse of the handle (result() before the completion arrived, loop
  destroyed first, a second result() on the futures that allow one),
  raised as a plain message.

RecvFuture and SendFuture have no "already consumed" shape: their
result() consumes the future, so a second call does not compile.

Also covers multiple sequential run() calls and concurrent operations on
the same loop.
"""

from std.testing import assert_true, assert_equal

from boucle.error import IOError
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.net.socket import Socket
from boucle.socle.platform import Errno
from boucle.watch import WatchLoop, AcceptFuture, ConnectFuture


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


def test_double_result_raises() raises:
    """Calling result() twice on a Future raises."""
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)

    var loop = WatchLoop(capacity=8)
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, target)
    loop.run()

    _ = connect_f.result()
    var caught = False
    try:
        _ = connect_f.result()
    except:
        caught = True
    assert_true(caught, "second result() should raise")

    var accepted = accept_f.result()
    accepted.close()
    client.close()
    server.close()


def test_not_done_before_run() raises:
    """Verify done() returns False before run() is called."""
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)

    var loop = WatchLoop(capacity=8)
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, target)

    assert_true(not connect_f.done(), "should not be done before run()")
    assert_true(not accept_f.done(), "should not be done before run()")

    loop.run()

    assert_true(connect_f.done(), "should be done after run()")
    assert_true(accept_f.done(), "should be done after run()")
    assert_true(connect_f.result().is_connected())
    var accepted = accept_f.result()
    accepted.close()
    client.close()
    server.close()


def test_sequential_runs() raises:
    """Multiple sequential run() calls on the same loop work correctly."""
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)

    var loop = WatchLoop(capacity=8)

    # Run 1: accept + connect.
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, target)
    loop.run()

    assert_true(connect_f.result().is_connected())
    var accepted = accept_f.result()

    # Run 2: send + recv on the established connection.
    var send_f = loop.send(client, List[UInt8](length=3, fill=97))
    var recv_f = loop.recv(accepted, List[UInt8](length=16, fill=0))
    loop.run()

    assert_equal(send_f^.result().count, 3)
    assert_equal(recv_f^.result().count, 3)

    # Run 3: timeout.
    var timer_f = loop.timeout(50)
    loop.run()

    assert_true(timer_f.result(), "timer should have expired")

    accepted.close()
    client.close()
    server.close()


def test_many_concurrent_ops() raises:
    """Multiple accept+connect pairs in a single run() call."""
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port

    var loop = WatchLoop(capacity=32)

    # Submit 4 connect+accept pairs.
    var clients = List[Socket]()
    var accept_futures = List[AcceptFuture]()
    var connect_futures = List[ConnectFuture]()

    for _ in range(4):
        var c = Socket.tcp_v4()
        var target = SocketAddrV4(127, 0, 0, 1, port=port)
        accept_futures.append(loop.accept(server))
        connect_futures.append(loop.connect(c, target))
        clients.append(c^)

    loop.run()

    for i in range(4):
        assert_true(
            connect_futures[i].done(),
            String("connect ", i, " should be done"),
        )
        assert_true(
            connect_futures[i].result().is_connected(),
            String("connect ", i, " should be CONNECTED"),
        )
        var accepted = accept_futures[i].result()
        accepted.close()

    for i in range(4):
        clients[i].close()
    server.close()


def test_recv_failure_reports_an_ioerror() raises:
    """A recv on a socket that was never connected fails with ENOTCONN.

    The point is the shape, not the errno: the message must be the one
    `IOError` produces, so a caller reads a name instead of decoding a
    number out of prose.
    """
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8)
    var recv_f = loop.recv(sock, List[UInt8](length=16, fill=0))
    loop.run()

    var message = String("")
    try:
        _ = recv_f^.result()
    except e:
        message = String(e)
    assert_equal(message, String(IOError(Errno.ENOTCONN)))
    sock.close()


def test_send_failure_reports_an_ioerror() raises:
    """A send on a socket that was never connected fails with EPIPE."""
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8)
    var send_f = loop.send(sock, List[UInt8](length=4, fill=65))
    loop.run()

    var message = String("")
    try:
        _ = send_f^.result()
    except e:
        message = String(e)
    assert_equal(message, String(IOError(Errno.EPIPE)))
    sock.close()


def test_accept_failure_reports_an_ioerror() raises:
    """An accept on a socket that never listened fails with EINVAL."""
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8)
    var accept_f = loop.accept(sock)
    loop.run()

    var message = String("")
    try:
        _ = accept_f.result()
    except e:
        message = String(e)
    assert_equal(message, String(IOError(Errno.EINVAL)))
    sock.close()


def test_misuse_keeps_its_own_message() raises:
    """Handle misuse is not a syscall failure and must not read like one.

    An errno would be a lie here — no syscall failed — so these keep the
    plain-message shape documented on result(). Asking a recv for its
    result before the loop has run is the only misuse left on a
    RecvFuture: result() consumes the future, so asking twice is a
    compile error, not a runtime one. The buffer stays with the loop,
    which drains the operation in run() below.
    """
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8)
    var recv_f = loop.recv(sock, List[UInt8](length=16, fill=0))

    var message = String("")
    try:
        _ = recv_f^.result()
    except e:
        message = String(e)
    assert_equal(message, "operation not complete")

    loop.run()
    sock.close()


def main() raises:
    test_double_result_raises()
    test_recv_failure_reports_an_ioerror()
    test_send_failure_reports_an_ioerror()
    test_accept_failure_reports_an_ioerror()
    test_misuse_keeps_its_own_message()
    test_not_done_before_run()
    test_sequential_runs()
    test_many_concurrent_ops()
    print("PASS: test_future_errors.mojo")
