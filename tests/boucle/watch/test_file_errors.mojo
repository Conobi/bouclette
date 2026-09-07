"""Test file I/O error paths and future drop safety."""

from std.ffi import external_call
from std.testing import assert_true
from boucle.buffer import AlignedBuffer
from boucle.watch.loop import WatchLoop
from boucle.watch.transfer import FileTransferFailed, FailureReason
from boucle.drivers.backend import Backend


def test_read_past_eof(backend: Backend) raises:
    """Read past EOF returns a short read."""
    var path = "/tmp/boucle_test_eof"
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512),
        Int32(0o644),
    )
    assert_true(fd >= 0, "open failed")
    var loop = WatchLoop(backend=backend)

    # Write 4 bytes.
    var wbuf = AlignedBuffer(capacity=4, fill=0xAA)
    var wf = loop.write(fd, wbuf^, UInt64(0))
    loop.run()
    _ = wf^.result()

    # Read 64 bytes from offset 0: only 4 should come back.
    var rbuf = AlignedBuffer(capacity=64, fill=0)
    var rf = loop.read(fd, rbuf^, UInt64(0))
    loop.run()
    var rr = rf^.result()
    assert_true(rr.count() == 4, "should be a short read of 4")

    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())


def test_drop_future_before_run(backend: Backend) raises:
    """Dropping a file future before `run()` is safe."""
    var path = "/tmp/boucle_test_drop"
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512),
        Int32(0o644),
    )
    assert_true(fd >= 0, "open failed")
    var loop = WatchLoop(backend=backend)
    var buf = AlignedBuffer(capacity=8, fill=0)
    var rf = loop.read(fd, buf^, UInt64(0))
    _ = rf^  # Drop without calling result().
    loop.run()  # Should complete without crash.

    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())


def main() raises:
    test_read_past_eof(Backend.IO_URING)
    print("PASS: short read past EOF (io_uring)")
    test_read_past_eof(Backend.EPOLL)
    print("PASS: short read past EOF (epoll)")
    test_drop_future_before_run(Backend.IO_URING)
    print("PASS: drop future before run (io_uring)")
    test_drop_future_before_run(Backend.EPOLL)
    print("PASS: drop future before run (epoll)")
