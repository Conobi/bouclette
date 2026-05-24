"""Sanity test: representative symbols are re-exported via the raw facade.

Touches one symbol per source module under the active arch's raw stubs
(`boucle._sys.linux.raw.x86_64` or `boucle._sys.linux.raw.aarch64`) to
force name resolution through the facade in
`boucle/_sys/linux/raw/__init__.mojo`. If any source module is dropped
from the facade's re-export list, this test fails to compile.

Arch-stable Linux ABI values (errno codes, AF_*, EPOLL flags, io_uring
opcodes) are asserted unconditionally. Arch-specific values (syscall
numbers, ucontext layout, register indices) are asserted against the
expected per-arch values via a comptime branch.

Implementation note: assertions use runtime `assert_equal` rather than
`comptime assert`. On Mojo 1.0.0b1 a `comptime if`/`return` does not
elide `comptime assert` evaluation in the unreachable branch, so a
hard-coded `comptime assert __NR_close == 3` would still fire on
aarch64. Runtime asserts are guarded by ordinary control flow and only
execute on the branch they live in.
"""

from boucle._sys import is_aarch64
from boucle._sys.linux.raw import syscall  # syscall.mojo
from boucle._sys.linux.raw import __NR_close, __kernel_timespec  # general.mojo
from boucle._sys.linux.raw import EPOLLIN, epoll_event  # epoll.mojo
from boucle._sys.linux.raw import EAGAIN, EINTR, EBADF  # errno.mojo
from boucle._sys.linux.raw import IORING_OP_NOP, IORING_OP_RECV, io_uring_buf  # io_uring.mojo
from boucle._sys.linux.raw import AF_INET, sockaddr_in, msghdr  # net.mojo
from boucle._sys.linux.raw import UCONTEXT_SIZE, REG_RIP  # ucontext.mojo
from std.testing import assert_equal


def main() raises:
    # Arch-stable Linux ABI values — identical across x86_64 and aarch64.
    assert_equal(EPOLLIN, 0x001, "epoll.mojo: EPOLLIN")
    assert_equal(EAGAIN, 11, "errno.mojo: EAGAIN")
    assert_equal(EINTR, 4, "errno.mojo: EINTR")
    assert_equal(EBADF, 9, "errno.mojo: EBADF")
    assert_equal(IORING_OP_NOP, 0, "io_uring.mojo: IORING_OP_NOP")
    assert_equal(IORING_OP_RECV, 27, "io_uring.mojo: IORING_OP_RECV")
    assert_equal(AF_INET, 2, "net.mojo: AF_INET")

    # Arch-specific values — syscall numbers and ucontext layout differ.
    comptime if is_aarch64:
        assert_equal(__NR_close, 57, "general.mojo (aarch64): __NR_close")
        assert_equal(UCONTEXT_SIZE, 4560, "ucontext.mojo (aarch64): UCONTEXT_SIZE")
        # REG_RIP is name-aliased to the aarch64 PC index (gregs[32]).
        assert_equal(REG_RIP, 32, "ucontext.mojo (aarch64): REG_RIP (PC index)")
    else:
        assert_equal(__NR_close, 3, "general.mojo (x86_64): __NR_close")
        assert_equal(UCONTEXT_SIZE, 968, "ucontext.mojo (x86_64): UCONTEXT_SIZE")
        assert_equal(REG_RIP, 16, "ucontext.mojo (x86_64): REG_RIP")

    # Construct one re-exported struct from each struct-bearing module to
    # confirm the type itself (not just the bare name) is reachable.
    var ev = epoll_event(events=0, data=0)
    _ = ev
    var buf = io_uring_buf()
    _ = buf
    var ts = __kernel_timespec(0, 0)
    _ = ts

    print("PASS")
