"""Sanity test: high-level Linux symbols are reachable via the facade.

Touches at least one symbol from each source-file group re-exported by
`boucle/socle/linux/__init__.mojo` (fd, mm, errno, ucontext) to force
the import resolver to walk every re-export.
"""

from boucle.socle.linux import (
    # fd.mojo
    UnsafeFd,
    NoFd,
    close,
    # mm.mojo
    MapFlags,
    ProtFlags,
    Advice,
    # errno.mojo
    Errno,
    unsafe_decode_result,
    # ucontext.mojo
    alloc_ucontext,
    free_ucontext,
)
from std.testing import assert_true, assert_false


def test_linux_facade() raises:
    # fd: comptime aliases and free function reachable
    var fd: UnsafeFd = NoFd
    assert_true(fd == -1)
    _ = close  # don't actually close anything

    # mm: flag/advice structs constructible via their comptime members
    var prot = ProtFlags.READ | ProtFlags.WRITE
    _ = prot
    var flags = MapFlags.PRIVATE
    _ = flags
    var advice = Advice.NORMAL
    _ = advice

    # errno: construct an Errno and use a decoder
    var e = Errno(errno=13)
    assert_true(e is Errno.EACCES)
    assert_false(e is Errno.EPERM)
    var ok = unsafe_decode_result[DType.int32](Scalar[DType.int64](0))
    assert_true(ok == 0)

    # ucontext: round-trip an alloc/free
    var ctx = alloc_ucontext()
    free_ucontext(ctx)

    print("PASS")


def main() raises:
    test_linux_facade()
    print("PASS: test_linux_facade.mojo")
