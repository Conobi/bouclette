"""Test WatchLoop file write + read round-trip on both backends."""

from std.ffi import external_call
from std.testing import assert_true
from boucle.buffer import AlignedBuffer
from boucle.watch.loop import WatchLoop
from boucle.drivers.backend import Backend


def _test_roundtrip(backend: Backend) raises:
    """Write bytes, read them back, compare."""
    var path = "/tmp/boucle_test_roundtrip"
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512),  # O_RDWR | O_CREAT | O_TRUNC
        Int32(0o644),
    )
    assert_true(fd >= 0, "open failed")

    var loop = WatchLoop(backend=backend)

    # Write 64 bytes.
    var wbuf = AlignedBuffer(capacity=64)
    for i in range(64):
        wbuf.append(UInt8(i))
    var wf = loop.write(fd, wbuf^, UInt64(0))
    loop.run()
    var wr = wf^.result()
    assert_true(wr.count() == 64, "write count wrong")

    # Read back.
    var rbuf = AlignedBuffer(capacity=64, fill=0)
    var rf = loop.read(fd, rbuf^, UInt64(0))
    loop.run()
    var rr = rf^.result()
    assert_true(rr.count() == 64, "read count wrong")
    var data = rr.transferred()
    for i in range(64):
        assert_true(data[i] == UInt8(i), "data mismatch")

    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())


def _test_read_at_offset(backend: Backend) raises:
    """Read at a non-zero offset, verify partial content."""
    var path = "/tmp/boucle_test_offset"
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512),
        Int32(0o644),
    )
    assert_true(fd >= 0, "open failed")
    var loop = WatchLoop(backend=backend)

    # Write 16 bytes: 0x00..0x0F.
    var wbuf = AlignedBuffer(capacity=16)
    for i in range(16):
        wbuf.append(UInt8(i))
    var wf = loop.write(fd, wbuf^, UInt64(0))
    loop.run()
    _ = wf^.result()

    # Read 4 bytes starting at offset 8.
    var rbuf = AlignedBuffer(capacity=4, fill=0)
    var rf = loop.read(fd, rbuf^, UInt64(8))
    loop.run()
    var rr = rf^.result()
    assert_true(rr.count() == 4, "should read 4 bytes")
    var data = rr.transferred()
    assert_true(data[0] == 0x08, "offset read byte 0 wrong")
    assert_true(data[3] == 0x0B, "offset read byte 3 wrong")

    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())


def _test_o_direct(backend: Backend) raises:
    """O_DIRECT write+read with 512-aligned buffer."""
    var path = "/tmp/boucle_test_odirect"
    # O_DIRECT = 0x4000 = 16384 on x86_64
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512 | 16384),  # O_RDWR|O_CREAT|O_TRUNC|O_DIRECT
        Int32(0o644),
    )
    if fd < 0:
        print("  (skipped: O_DIRECT not supported on this filesystem)")
        return
    var loop = WatchLoop(backend=backend)

    # Write 512 bytes, 512-aligned.
    var wbuf = AlignedBuffer(capacity=512, alignment=512, fill=0xDD)
    var wf = loop.write(fd, wbuf^, UInt64(0))
    loop.run()
    var wr = wf^.result()
    assert_true(wr.count() == 512, "O_DIRECT write count wrong")

    # Read 512 bytes back, 512-aligned.
    var rbuf = AlignedBuffer(capacity=512, alignment=512, fill=0)
    var rf = loop.read(fd, rbuf^, UInt64(0))
    loop.run()
    var rr = rf^.result()
    assert_true(rr.count() == 512, "O_DIRECT read count wrong")
    assert_true(rr.transferred()[0] == 0xDD, "O_DIRECT data wrong")
    assert_true(
        rr.transferred()[511] == 0xDD, "O_DIRECT last byte wrong"
    )

    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())


def main() raises:
    _test_roundtrip(Backend.IO_URING)
    print("PASS: file round-trip on io_uring")
    _test_roundtrip(Backend.EPOLL)
    print("PASS: file round-trip on epoll")
    _test_read_at_offset(Backend.IO_URING)
    print("PASS: read at offset (io_uring)")
    _test_read_at_offset(Backend.EPOLL)
    print("PASS: read at offset (epoll)")
    _test_o_direct(Backend.IO_URING)
    print("PASS: O_DIRECT (io_uring)")
    _test_o_direct(Backend.EPOLL)
    print("PASS: O_DIRECT (epoll)")
