"""Test WatchLoop.fsync and fdatasync."""

from std.ffi import external_call
from std.testing import assert_true
from boucle.buffer import AlignedBuffer
from boucle.watch.loop import WatchLoop
from boucle.drivers.backend import Backend


def _test_fsync(backend: Backend) raises:
    """Write, fsync, fdatasync — all complete without error."""
    var path = "/tmp/boucle_test_fsync"
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512),
        Int32(0o644),
    )
    assert_true(fd >= 0, "open failed")
    var loop = WatchLoop(backend=backend)

    # Write.
    var wbuf = AlignedBuffer(capacity=8, fill=0x42)
    var wf = loop.write(fd, wbuf^, UInt64(0))
    # fsync.
    var sf = loop.fsync(fd)
    # fdatasync.
    var sf2 = loop.fsync(fd, datasync=True)
    loop.run()

    _ = wf^.result()
    sf^.result()
    sf2^.result()

    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())


def main() raises:
    _test_fsync(Backend.IO_URING)
    print("PASS: fsync on io_uring")
    _test_fsync(Backend.EPOLL)
    print("PASS: fsync on epoll")
