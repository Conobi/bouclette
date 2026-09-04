"""The WatchLoop owns every in-flight operation state until it is settled.

A Future handle and the loop share each heap-allocated operation state.
The loop keeps a registry of the states still in flight so that no
matter which side goes away first — the handle, or the loop itself —
the state is freed exactly once and a surviving handle can report that
its loop is gone instead of waiting forever.

socketpair(2) is called directly: it is the only socket constructor
boucle.net.Socket does not wrap.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.handle import OwnedHandle
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.net.socket import Socket
from boucle.socle.linux.errno import get_errno
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


def test_orphaned_future_freed_when_loop_destroyed_without_run() raises:
    """A dropped RecvFuture is released by the loop's own destruction.

    The recv never reaches the kernel (SQEs are only submitted from
    run()), so the only thing keeping its state alive is the loop's
    registry. Destroying the loop must free it rather than leak it.
    """
    var fds = _make_socketpair()
    var reader = Socket(OwnedHandle(raw=fds[0]))
    var writer = Socket(OwnedHandle(raw=fds[1]))
    var loop = WatchLoop()

    var recv_f = loop.recv(reader, List[UInt8](length=16, fill=0))
    _ = recv_f^  # Dropped while the recv is still in flight.

    assert_equal(
        loop.in_flight_count(), 1, "orphaned recv should still be tracked"
    )
    _ = loop^  # Destroyed without run(): must free the orphaned state.

    reader.close()
    writer.close()


def test_live_future_outliving_loop_reports_loop_gone() raises:
    """A TimerFuture that outlives its loop reports the loss instead of hanging.

    done() stays False (no completion was ever delivered), result()
    raises a clear error, and dropping the future afterwards frees the
    state itself since the loop can no longer do it.
    """
    var loop = WatchLoop()
    var timer_f = loop.timeout(10_000)
    assert_equal(loop.in_flight_count(), 1, "timer should be tracked")

    _ = loop^  # Destroyed while the timer is still armed.

    assert_true(not timer_f.done(), "no completion can have been delivered")
    var caught = False
    try:
        _ = timer_f.result()
    except e:
        caught = "loop destroyed" in String(e)
        assert_true(caught, String("unexpected error message: ", String(e)))
    assert_true(caught, "result() should raise once the loop is gone")
    _ = timer_f^  # Last owner: frees the state.


def test_live_future_outliving_loop_after_kernel_submission() raises:
    """Same as above, but the timer was really handed to the kernel first.

    A non-blocking tick pushes the SQE to the kernel without waiting for
    the completion. Destroying the loop then tears the driver down with
    a live kernel timer: the kernel discards it, no callback fires, and
    the future must still report that its loop is gone. The process must
    not wait for the 10 s timer.
    """
    var loop = WatchLoop()
    var timer_f = loop.timeout(10_000)
    _ = loop._driver.tick(wait=False)  # Submit to the kernel, don't wait.
    assert_equal(loop.in_flight_count(), 1, "timer should be tracked")

    _ = loop^

    assert_true(not timer_f.done(), "no completion can have been delivered")
    var caught = False
    try:
        _ = timer_f.result()
    except e:
        caught = "loop destroyed" in String(e)
    assert_true(caught, "result() should raise once the loop is gone")
    _ = timer_f^


def test_in_flight_registry_empties_after_run() raises:
    """Every settled operation leaves the registry once run() returns."""
    var fds = _make_socketpair()
    var reader = Socket(OwnedHandle(raw=fds[0]))
    var writer = Socket(OwnedHandle(raw=fds[1]))
    var loop = WatchLoop()

    var send_f = loop.send(writer, List[UInt8](length=4, fill=100))
    var recv_f = loop.recv(reader, List[UInt8](length=16, fill=0))
    var timer_f = loop.timeout(1)
    assert_equal(loop.in_flight_count(), 3, "three ops should be tracked")

    loop.run()

    assert_equal(loop.in_flight_count(), 0, "registry should be empty")
    assert_equal(send_f^.result().count, 4)
    assert_equal(recv_f^.result().count, 4)
    assert_true(timer_f.result(), "timer should have expired")

    reader.close()
    writer.close()


def test_composite_dropped_early_freed_when_loop_destroyed_without_run() raises:
    """A dropped ConnectWithTimeoutFuture is released by the loop's destruction."""
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)
    var loop = WatchLoop()

    var connect_f = loop.connect_with_timeout(client, target, timeout_ms=5000)
    _ = connect_f^  # Dropped while connect and timeout are both in flight.

    assert_equal(
        loop.in_flight_count(), 1, "the composite is one registry entry"
    )
    assert_equal(loop.pending_composites(), 1, "composite awaits its cancel")
    _ = loop^  # Destroyed without run(): must free the orphaned composite.

    client.close()
    server.close()


def test_live_composite_outliving_loop_reports_loop_gone() raises:
    """A ConnectWithTimeoutFuture that outlives its loop reports the loss."""
    var server = _make_tcp_listener()
    var port = server.local_addr_v4().port
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)
    var loop = WatchLoop()

    var connect_f = loop.connect_with_timeout(client, target, timeout_ms=5000)
    _ = loop^

    assert_true(not connect_f.done(), "no completion can have been delivered")
    var caught = False
    try:
        _ = connect_f.result()
    except e:
        caught = "loop destroyed" in String(e)
    assert_true(caught, "result() should raise once the loop is gone")
    _ = connect_f^

    client.close()
    server.close()


def main() raises:
    test_orphaned_future_freed_when_loop_destroyed_without_run()
    print("ok: orphaned future freed with loop")
    test_live_future_outliving_loop_reports_loop_gone()
    print("ok: live future reports loop gone")
    test_live_future_outliving_loop_after_kernel_submission()
    print("ok: live future reports loop gone after kernel submission")
    test_in_flight_registry_empties_after_run()
    print("ok: registry empties after run")
    test_composite_dropped_early_freed_when_loop_destroyed_without_run()
    print("ok: orphaned composite freed with loop")
    test_live_composite_outliving_loop_reports_loop_gone()
    print("ok: live composite reports loop gone")
    print("PASS: test_loop_owns_in_flight.mojo")
