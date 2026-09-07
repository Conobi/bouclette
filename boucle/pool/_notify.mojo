"""Eventfd helpers for waking the event loop from a worker thread.

`read(2)`/`write(2)` are issued via the raw syscall trampoline
(`boucle.socle.linux.raw.syscall`), not `external_call["read"/"write"]`:
the stdlib's own `FileDescriptor`/`File` types declare `external_call`
bindings for those same C symbols with a different argument ABI
(`c_ssize_t`-typed, MLIR-index arguments), and Mojo requires every
`external_call` to a given symbol name in one compilation to agree on
signature. Declaring our own conflicting `"read"`/`"write"` binding fails
to lower at the LLVM stage. `eventfd(2)` has no such stdlib user, so it is
safe to bind directly via `external_call`.
"""

from std.ffi import external_call
from std.memory import Pointer
from boucle.socle.linux.raw import (
    EFD_CLOEXEC,
    EFD_NONBLOCK,
    __NR_read,
    __NR_write,
    syscall,
)
from boucle.handle import RawHandle


def create_eventfd() raises -> RawHandle:
    """Create a non-blocking, close-on-exec eventfd.

    Returns:
        The eventfd file descriptor.
    """
    var fd = external_call["eventfd", Int32](
        Int32(0), Int32(EFD_CLOEXEC | EFD_NONBLOCK)
    )
    if fd < 0:
        raise "eventfd creation failed"
    return fd


def _notify_raw(fd: RawHandle):
    """Write 1 to an eventfd to wake the event loop.

    Called from worker threads after pushing a result.
    """
    var val = UInt64(1)
    _ = syscall[__NR_write, Scalar[DType.int64]](fd, Pointer(to=val), Int(8))


def drain_eventfd(fd: RawHandle):
    """Read and discard the eventfd counter.

    Called from the event loop to clear the wakeup.
    Non-blocking: returns immediately if the counter is 0.
    """
    var val = UInt64(0)
    _ = syscall[__NR_read, Scalar[DType.int64]](fd, Pointer(to=val), Int(8))
