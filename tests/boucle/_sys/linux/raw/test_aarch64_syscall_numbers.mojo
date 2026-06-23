"""Golden table for aarch64 Linux syscall numbers.

Values are sourced from `linux/include/uapi/asm-generic/unistd.h`. This
test only runs the assertions on aarch64; on other arches it prints
SKIP and returns successfully so the run_tests.sh sweep stays uniform.
"""

from boucle._sys import is_aarch64
from boucle._sys.linux.raw.aarch64.general import (
    __NR_close,
    __NR_mmap,
    __NR_mprotect,
    __NR_munmap,
    __NR_madvise,
    __NR_dup,
    __NR_socket,
    __NR_bind,
    __NR_listen,
    __NR_setsockopt,
    __NR_socketpair,
    __NR_epoll_pwait,
    __NR_epoll_wait,
    __NR_epoll_ctl,
    __NR_epoll_create1,
    __NR_io_uring_setup,
    __NR_io_uring_enter,
    __NR_io_uring_register,
)
from std.testing import assert_equal


def main() raises:
    comptime if not is_aarch64:
        print("SKIP: aarch64-only test")
        return

    # Source: linux/include/uapi/asm-generic/unistd.h
    assert_equal(__NR_close, 57)
    assert_equal(__NR_mmap, 222)
    assert_equal(__NR_mprotect, 226)
    assert_equal(__NR_munmap, 215)
    assert_equal(__NR_madvise, 233)
    assert_equal(__NR_dup, 23)
    assert_equal(__NR_socket, 198)
    assert_equal(__NR_bind, 200)
    assert_equal(__NR_listen, 201)
    assert_equal(__NR_setsockopt, 208)
    assert_equal(__NR_socketpair, 199)
    assert_equal(__NR_epoll_pwait, 22)
    # aarch64 has no __NR_epoll_wait in the UAPI table; Boucle aliases
    # __NR_epoll_wait to __NR_epoll_pwait to keep the facade re-export
    # name stable. Verify the alias holds.
    assert_equal(__NR_epoll_wait, __NR_epoll_pwait)
    assert_equal(__NR_epoll_ctl, 21)
    assert_equal(__NR_epoll_create1, 20)
    assert_equal(__NR_io_uring_setup, 425)
    assert_equal(__NR_io_uring_enter, 426)
    assert_equal(__NR_io_uring_register, 427)

    print("All aarch64 syscall number assertions passed.")
