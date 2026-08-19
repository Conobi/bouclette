"""Tests for Future error paths and edge cases.

Covers: double result(), result() before run(), multiple sequential
run() calls, and concurrent operations on the same loop.

Uses direct syscalls for server setup due to a Mojo 1.0.0 compiler
bug affecting Socket.bind() through parametric inlining.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.sys.info import size_of
from std.testing import assert_true, assert_equal

from boucle.watch import WatchLoop, AcceptFuture, ConnectFuture
from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.socle.linux.raw import sockaddr_in, socklen_t
from boucle.socle.linux.errno import get_errno


def _make_tcp_listener() raises -> Socket:
    """Create a TCP v4 listener on 127.0.0.1:0 using direct syscalls."""
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
    """Get the ephemeral port assigned to a bound socket."""
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


def _make_client_socket() raises -> Socket:
    """Create a non-blocking TCP client socket."""
    var fd = external_call["socket", Int32](
        Int32(2), Int32(1 | 2048 | 524288), Int32(6)
    )
    if fd < 0:
        raise String("socket failed: errno ", Int(get_errno()))
    return Socket(OwnedHandle(raw=fd))


def test_double_result_raises() raises:
    """Calling result() twice on a Future raises."""
    var server = _make_tcp_listener()
    var port = _get_port(server)
    var client = _make_client_socket()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)

    var loop = WatchLoop(sq_entries=8)
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
    var port = _get_port(server)
    var client = _make_client_socket()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)

    var loop = WatchLoop(sq_entries=8)
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
    var port = _get_port(server)
    var client = _make_client_socket()
    var target = SocketAddrV4(127, 0, 0, 1, port=port)

    var loop = WatchLoop(sq_entries=8)

    # Run 1: accept + connect.
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, target)
    loop.run()

    assert_true(connect_f.result().is_connected())
    var accepted = accept_f.result()

    # Run 2: send + recv on the established connection.
    var msg = String("abc")
    var recv_buf = InlineArray[UInt8, 16](fill=UInt8(0))
    var recv_span = Span[UInt8, MutAnyOrigin](
        unsafe_ptr=Pointer[UInt8, MutAnyOrigin](
            unsafe_from_address=Int(Pointer(to=recv_buf))
        ),
        length=16,
    )
    var send_f = loop.send(client, msg.as_bytes())
    var recv_f = loop.recv(accepted, recv_span)
    loop.run()

    assert_equal(send_f.result(), 3)
    assert_equal(recv_f.result(), 3)

    # Run 3: timeout.
    var timer_f = loop.timeout(ms=50)
    loop.run()

    assert_true(timer_f.result(), "timer should have expired")

    accepted.close()
    client.close()
    server.close()


def test_many_concurrent_ops() raises:
    """Multiple accept+connect pairs in a single run() call."""
    var server = _make_tcp_listener()
    var port = _get_port(server)

    var loop = WatchLoop(sq_entries=32)

    # Submit 4 connect+accept pairs.
    var clients = List[Socket]()
    var accept_futures = List[AcceptFuture]()
    var connect_futures = List[ConnectFuture]()

    for _ in range(4):
        var c = _make_client_socket()
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


def main() raises:
    test_double_result_raises()
    test_not_done_before_run()
    test_sequential_runs()
    test_many_concurrent_ops()
    print("PASS: test_future_errors.mojo")
