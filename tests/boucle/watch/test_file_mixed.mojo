"""Test file ops batched, mixed with network ops, and teardown."""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_true
from boucle.buffer import AlignedBuffer
from boucle.watch.loop import WatchLoop
from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.drivers.backend import Backend
from boucle.socle.linux.errno import get_errno


def _make_socketpair() raises -> Tuple[Int32, Int32]:
    """Create a connected AF_UNIX SOCK_STREAM socketpair."""
    var fds = InlineArray[Int32, 2](fill=Int32(0))
    var fds_p = Pointer(to=fds)
    var res = external_call["socketpair", Int32](
        Int32(1),
        Int32(1 | 2048 | 524288),
        Int32(0),
        fds_p,
    )
    if res < 0:
        raise String("socketpair failed: errno ", Int(get_errno()))
    return (fds[0], fds[1])


def test_batched_file_ops(backend: Backend) raises:
    """Multiple file ops in one `run()`."""
    var path = "/tmp/boucle_test_batch"
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512),
        Int32(0o644),
    )
    assert_true(fd >= 0, "open failed")
    var loop = WatchLoop(backend=backend)

    # Submit 3 writes at different offsets.
    var b1 = AlignedBuffer(capacity=8, fill=0x11)
    var b2 = AlignedBuffer(capacity=8, fill=0x22)
    var b3 = AlignedBuffer(capacity=8, fill=0x33)
    var wf1 = loop.write(fd, b1^, UInt64(0))
    var wf2 = loop.write(fd, b2^, UInt64(8))
    var wf3 = loop.write(fd, b3^, UInt64(16))
    loop.run()

    assert_true(wf1^.result().count() == 8, "write 1 wrong")
    assert_true(wf2^.result().count() == 8, "write 2 wrong")
    assert_true(wf3^.result().count() == 8, "write 3 wrong")

    # Read all 24 bytes back.
    var rbuf = AlignedBuffer(capacity=24, fill=0)
    var rf = loop.read(fd, rbuf^, UInt64(0))
    loop.run()
    var rr = rf^.result()
    assert_true(rr.count() == 24, "read wrong count")
    var data = rr.transferred()
    assert_true(data[0] == 0x11, "offset 0 wrong")
    assert_true(data[8] == 0x22, "offset 8 wrong")
    assert_true(data[16] == 0x33, "offset 16 wrong")

    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())


def test_mixed_file_and_network(backend: Backend) raises:
    """File write + TCP socketpair send+recv in the same `run()`."""
    var path = "/tmp/boucle_test_mixed"
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512),
        Int32(0o644),
    )
    assert_true(fd >= 0, "open failed")
    var loop = WatchLoop(backend=backend)

    # File write.
    var fbuf = AlignedBuffer(capacity=4, fill=0xAA)
    var wf = loop.write(fd, fbuf^, UInt64(0))

    # Network: socketpair, send+recv.
    var fds = _make_socketpair()
    var sock_a = Socket(OwnedHandle(raw=fds[0]))
    var sock_b = Socket(OwnedHandle(raw=fds[1]))
    var send_buf = List[UInt8]()
    send_buf.append(0xBB)
    send_buf.append(0xCC)
    var sf = loop.send(sock_a, send_buf^)
    var rf = loop.recv(sock_b, List[UInt8](length=2, fill=0))

    loop.run()

    # All three should complete.
    assert_true(wf^.result().count() == 4, "file write wrong")
    assert_true(sf^.result().count == 2, "send wrong")
    assert_true(rf^.result().count == 2, "recv wrong")

    # Keep sockets alive past run() — ASAP destruction would close them.
    _ = sock_a.raw()
    _ = sock_b.raw()

    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())


def test_loop_destroyed_with_file_op(backend: Backend) raises:
    """Destroy loop with a file op in flight: no crash."""
    var path = "/tmp/boucle_test_teardown"
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512),
        Int32(0o644),
    )
    assert_true(fd >= 0, "open failed")
    _test_teardown_inner(fd, backend)

    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())


def _test_teardown_inner(fd: Int32, backend: Backend) raises:
    """Scope the loop so it is destroyed with a file op in flight."""
    var loop = WatchLoop(backend=backend)
    var buf = AlignedBuffer(capacity=8, fill=0)
    _ = loop.write(fd, buf^, UInt64(0))


def main() raises:
    test_batched_file_ops(Backend.IO_URING)
    print("PASS: batched file ops (io_uring)")
    test_batched_file_ops(Backend.EPOLL)
    print("PASS: batched file ops (epoll)")
    test_mixed_file_and_network(Backend.IO_URING)
    print("PASS: mixed file+network (io_uring)")
    test_loop_destroyed_with_file_op(Backend.IO_URING)
    print("PASS: loop teardown with file op (io_uring)")
    test_loop_destroyed_with_file_op(Backend.EPOLL)
    print("PASS: loop teardown with file op (epoll)")
