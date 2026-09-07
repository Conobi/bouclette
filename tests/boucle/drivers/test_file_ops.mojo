"""Test file read/write/fsync at the driver level on both backends."""

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_true
from boucle.drivers.auto import AutoDriver
from boucle.drivers.backend import Backend
from boucle.proactor.completion import Completion


struct _FileResult:
    """Records a single file operation result."""

    var result: Int

    def __init__(out self):
        """Construct with sentinel value."""
        self.result = -999

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Completion callback: store the result."""
        var slot = Pointer[_FileResult, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        slot[].result = result


def _test_on_backend(backend: Backend) raises:
    """Write 4 bytes, fsync, read them back, verify."""
    var driver = AutoDriver(backend=backend)

    var path = "/tmp/boucle_test_file_ops"
    var fd = external_call["open", Int32](
        path.unsafe_ptr(),
        Int32(2 | 64 | 512),  # O_RDWR | O_CREAT | O_TRUNC
        Int32(0o644),
    )
    assert_true(fd >= 0, "open failed")

    # Write 4 bytes.
    var write_buf = unsafe_alloc[UInt8](4)
    write_buf[unsafe_offset=0] = 0xDE
    write_buf[unsafe_offset=1] = 0xAD
    write_buf[unsafe_offset=2] = 0xBE
    write_buf[unsafe_offset=3] = 0xEF

    var slot = _FileResult()
    var slot_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var c = unsafe_alloc[Completion](1)
    c.unsafe_write(Completion(invoke=_FileResult.on_complete, context=slot_ctx))

    var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(write_buf)
    )
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(c)
    )
    driver.write(fd, buf_ptr, UInt32(4), UInt64(0), cmp_ptr)
    _ = driver.tick(wait=True, timeout_ms=2000)
    assert_true(slot.result == 4, "write should return 4 bytes")

    # Fsync.
    slot.result = -999
    c.unsafe_write(Completion(invoke=_FileResult.on_complete, context=slot_ctx))
    driver.fsync(fd, False, cmp_ptr)
    _ = driver.tick(wait=True, timeout_ms=2000)
    assert_true(slot.result == 0, "fsync should return 0")

    # Read back.
    var read_buf = unsafe_alloc[UInt8](4)
    slot.result = -999
    c.unsafe_write(Completion(invoke=_FileResult.on_complete, context=slot_ctx))
    var rbuf_ptr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(read_buf)
    )
    driver.read(fd, rbuf_ptr, UInt32(4), UInt64(0), cmp_ptr)
    _ = driver.tick(wait=True, timeout_ms=2000)
    assert_true(slot.result == 4, "read should return 4 bytes")
    assert_true(read_buf[unsafe_offset=0] == 0xDE, "wrong byte 0")
    assert_true(read_buf[unsafe_offset=3] == 0xEF, "wrong byte 3")

    # Clean up.
    _ = external_call["close", Int32](fd)
    _ = external_call["unlink", Int32](path.unsafe_ptr())
    write_buf.unsafe_free()
    read_buf.unsafe_free()
    c.unsafe_free()


def main() raises:
    _test_on_backend(Backend.IO_URING)
    print("PASS: file ops on io_uring")
    _test_on_backend(Backend.EPOLL)
    print("PASS: file ops on epoll (worker pool)")
