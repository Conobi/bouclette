"""Golden table for Linux syscall numbers.

Values are sourced from kernel headers. On x86_64, from
arch/x86/entry/syscalls/syscall_64.tbl. On aarch64, from
include/uapi/asm-generic/unistd.h.
"""

from boucle.socle import is_aarch64
from boucle.socle.linux.raw.general import (
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
    __NR_epoll_wait,
    __NR_epoll_ctl,
    __NR_epoll_create1,
    __NR_io_uring_setup,
    __NR_io_uring_enter,
    __NR_io_uring_register,
)
from std.testing import assert_equal


def test_syscall_numbers() raises:
    comptime if is_aarch64:
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
        assert_equal(__NR_epoll_wait, 22)
        assert_equal(__NR_epoll_ctl, 21)
        assert_equal(__NR_epoll_create1, 20)
        assert_equal(__NR_io_uring_setup, 425)
        assert_equal(__NR_io_uring_enter, 426)
        assert_equal(__NR_io_uring_register, 427)
    else:
        assert_equal(__NR_close, 3)
        assert_equal(__NR_mmap, 9)
        assert_equal(__NR_mprotect, 10)
        assert_equal(__NR_munmap, 11)
        assert_equal(__NR_madvise, 28)
        assert_equal(__NR_dup, 32)
        assert_equal(__NR_socket, 41)
        assert_equal(__NR_bind, 49)
        assert_equal(__NR_listen, 50)
        assert_equal(__NR_setsockopt, 54)
        assert_equal(__NR_socketpair, 53)
        assert_equal(__NR_epoll_wait, 232)
        assert_equal(__NR_epoll_ctl, 233)
        assert_equal(__NR_epoll_create1, 291)
        assert_equal(__NR_io_uring_setup, 425)
        assert_equal(__NR_io_uring_enter, 426)
        assert_equal(__NR_io_uring_register, 427)


def main() raises:
    test_syscall_numbers()
    print("PASS: test_aarch64_syscall_numbers.mojo")
