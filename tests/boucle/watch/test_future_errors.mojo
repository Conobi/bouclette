"""Tests for Future error paths and edge cases.

Covers the error shapes a Future can report:

- a syscall failure on accept/connect/timer, raised as an `IOError`
  carrying the errno, so the message names the error (`EINVAL (22)`)
  instead of spelling out a number;
- a syscall failure on recv/send, raised as a `TransferFailed` with
  `reason == IO`, the errno in `error`, and the buffer recoverable
  through `take_buffer()`;
- misuse of the handle (result() before the completion arrived, a
  second result() on the futures that allow one). On recv/send this is
  `TransferFailed` with `reason == NOT_DONE` and no buffer; on the
  other futures a plain message.

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
from boucle.watch import (
    WatchLoop,
    AcceptFuture,
    ConnectFuture,
    FailureReason,
    TransferFailed,
)


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


def test_recv_failure_returns_the_buffer() raises:
    """A recv on a never-connected socket fails with ENOTCONN and gives the buffer back.

    The point is the shape: `TransferFailed` with `reason == IO`, the
    errno in `error`, and the very list that was submitted recoverable
    from the failure.
    """
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8)
    var buf = List[UInt8](length=16, fill=0)
    var storage = Int(buf.unsafe_ptr())
    var recv_f = loop.recv(sock, buf^)
    loop.run()

    var reason = FailureReason.NOT_DONE
    var error = IOError(positive_errno=0)
    var back = Optional[List[UInt8]]()
    try:
        _ = recv_f^.result()
    except e:
        reason = e.reason
        error = e.error
        back = e^.take_buffer()
    assert_true(reason == FailureReason.IO, "a completed failure is IO")
    assert_true(error == IOError(Errno.ENOTCONN))
    assert_true(Bool(back), "the buffer comes back on IO failure")
    assert_equal(len(back.value()), 16)
    assert_equal(Int(back.value().unsafe_ptr()), storage, "same storage")
    sock.close()


def test_send_failure_returns_the_buffer() raises:
    """A send on a never-connected socket fails with EPIPE and gives the buffer back."""
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8)
    var buf = List[UInt8](length=4, fill=65)
    var storage = Int(buf.unsafe_ptr())
    var send_f = loop.send(sock, buf^)
    loop.run()

    var reason = FailureReason.NOT_DONE
    var error = IOError(positive_errno=0)
    var back = Optional[List[UInt8]]()
    try:
        _ = send_f^.result()
    except e:
        reason = e.reason
        error = e.error
        back = e^.take_buffer()
    assert_true(reason == FailureReason.IO)
    assert_true(error == IOError(Errno.EPIPE))
    assert_true(Bool(back))
    assert_equal(len(back.value()), 4)
    assert_equal(Int(back.value()[0]), 65, "the bytes are untouched")
    assert_equal(Int(back.value().unsafe_ptr()), storage, "same storage")
    sock.close()


def test_typed_failure_degrades_to_a_readable_message() raises:
    """Through a bare `raises` frame the failure still reads as reason and errno."""
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8)
    var recv_f = loop.recv(sock, List[UInt8](length=16, fill=0))
    loop.run()

    var message = String("")
    try:
        _ = recv_f^.result()
    except e:
        message = String(e)
    assert_equal(message, String("IO: ", IOError(Errno.ENOTCONN)))
    sock.close()


def test_result_before_run_is_not_done() raises:
    """Asking a recv for its result before the loop ran is NOT_DONE, no buffer.

    No syscall failed, so the errno is EINVAL by convention. The buffer
    stays with the loop, which drains the operation in run() below and
    releases it.
    """
    var sock = Socket.tcp_v4()
    var loop = WatchLoop(capacity=8)
    var recv_f = loop.recv(sock, List[UInt8](length=16, fill=0))

    var reason = FailureReason.IO
    var back = Optional[List[UInt8]](List[UInt8]())
    var message = String("")
    try:
        _ = recv_f^.result()
    except e:
        reason = e.reason
        message = String(e)
        back = e^.take_buffer()
    assert_true(reason == FailureReason.NOT_DONE)
    assert_true(not Bool(back), "the buffer is still in flight")
    assert_equal(message, "NOT_DONE: EINVAL (22)")

    loop.run()
    assert_equal(loop.in_flight_count(), 0)
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


def main() raises:
    test_double_result_raises()
    test_recv_failure_returns_the_buffer()
    test_send_failure_returns_the_buffer()
    test_accept_failure_reports_an_ioerror()
    test_typed_failure_degrades_to_a_readable_message()
    test_result_before_run_is_not_done()
    test_not_done_before_run()
    test_sequential_runs()
    test_many_concurrent_ops()
    print("PASS: test_future_errors.mojo")
