"""Runtime verification that __NR_* constants match the real kernel.

Complements test_aarch64_syscall_numbers.mojo (comptime value assertions)
by proving the constants produce correct results at runtime. If a constant
is wrong for the current architecture, the syscall returns -ENOSYS.
"""

from boucle.socle.linux.raw import (
    __NR_getpid, __NR_pipe2, __NR_read, __NR_write, __NR_close,
    EBADF,
)
from boucle.socle.linux.raw import syscall
from std.testing import assert_true, assert_equal


def test_getpid() raises:
    """__NR_getpid returns a valid PID."""
    var pid = syscall[__NR_getpid, Int64]()
    assert_true(pid > 0, "__NR_getpid returned non-positive value")


def test_write_read_roundtrip() raises:
    """__NR_pipe2 + __NR_write + __NR_read round-trip a byte."""
    var pipefd = InlineArray[Int32, 2](fill=0)
    var ret = syscall[__NR_pipe2, Int64](
        Pointer(to=pipefd).unsafe_bitcast[Int32](), Int32(0)
    )
    assert_equal(Int(ret), 0, "pipe2 failed")

    var msg = UInt8(42)
    var written = syscall[__NR_write, Int64](
        pipefd[1], Pointer(to=msg), UInt64(1)
    )
    assert_equal(Int(written), 1, "write failed")

    var buf = UInt8(0)
    var read_n = syscall[__NR_read, Int64](
        pipefd[0], Pointer(to=buf), UInt64(1)
    )
    assert_equal(Int(read_n), 1, "read failed")
    assert_equal(buf, UInt8(42), "roundtrip data mismatch")

    _ = syscall[__NR_close, Int64](pipefd[0])
    _ = syscall[__NR_close, Int64](pipefd[1])


def test_close_invalid_fd() raises:
    """__NR_close with invalid fd returns -EBADF, not -ENOSYS."""
    var ret = syscall[__NR_close, Int64](Int32(-1))
    assert_equal(Int(ret), -Int(EBADF), "expected -EBADF")


def main() raises:
    test_getpid()
    test_write_read_roundtrip()
    test_close_invalid_fd()
    print("PASS: test_syscall_verification.mojo")
