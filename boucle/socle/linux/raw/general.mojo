from boucle.socle.linux.raw.ctypes import c_int, c_long, c_ulong, c_longlong
from std.sys.info import CompilationTarget


@always_inline("nodebug")
def _pick[x86: UInt64, arm: UInt64]() -> UInt64:
    """Select a value based on the target architecture."""
    comptime if CompilationTarget.is_x86():
        return x86
    else:
        return arm


# Syscall numbers
comptime __NR_read = _pick[0, 63]()
comptime __NR_write = _pick[1, 64]()
comptime __NR_close = _pick[3, 57]()
comptime __NR_mmap = _pick[9, 222]()
comptime __NR_mprotect = _pick[10, 226]()
comptime __NR_munmap = _pick[11, 215]()
comptime __NR_madvise = _pick[28, 233]()
comptime __NR_dup = _pick[32, 23]()
comptime __NR_socket = _pick[41, 198]()
comptime __NR_bind = _pick[49, 200]()
comptime __NR_listen = _pick[50, 201]()
comptime __NR_setsockopt = _pick[54, 208]()
comptime __NR_socketpair = _pick[53, 199]()
# aarch64 has only epoll_pwait (no legacy epoll_wait)
comptime __NR_epoll_wait = _pick[232, 22]()
comptime __NR_epoll_ctl = _pick[233, 21]()
comptime __NR_epoll_create1 = _pick[291, 20]()
comptime __NR_io_uring_setup = _pick[425, 425]()
comptime __NR_io_uring_enter = _pick[426, 426]()
comptime __NR_io_uring_register = _pick[427, 427]()

# mmap constants (arch-stable)
comptime MAP_FILE = 0
comptime MAP_SHARED = 1
comptime MAP_PRIVATE = 2
comptime MAP_SHARED_VALIDATE = 3
comptime MAP_TYPE = 15
comptime MAP_FIXED = 16
comptime MAP_ANONYMOUS = 32
comptime MAP_GROWSDOWN = 256
comptime MAP_DENYWRITE = 2048
comptime MAP_EXECUTABLE = 4096
comptime MAP_LOCKED = 8192
comptime MAP_NORESERVE = 16384
comptime MAP_POPULATE = 32768
comptime MAP_NONBLOCK = 65536
comptime MAP_STACK = 131072
comptime MAP_HUGETLB = 262144
comptime MAP_SYNC = 524288
comptime MAP_FIXED_NOREPLACE = 1048576
comptime MAP_UNINITIALIZED = 67108864
comptime MAP_HUGE_SHIFT = 26
comptime MAP_HUGE_MASK = 63
comptime MAP_HUGE_16KB = 939524096
comptime MAP_HUGE_64KB = 1073741824
comptime MAP_HUGE_512KB = 1275068416
comptime MAP_HUGE_1MB = 1342177280
comptime MAP_HUGE_2MB = 1409286144
comptime MAP_HUGE_8MB = 1543503872
comptime MAP_HUGE_16MB = 1610612736
comptime MAP_HUGE_32MB = 1677721600
comptime MAP_HUGE_256MB = 1879048192
comptime MAP_HUGE_512MB = 1946157056
comptime MAP_HUGE_1GB = 2013265920
comptime MAP_HUGE_2GB = 2080374784
comptime MAP_HUGE_16GB = 2281701376

comptime PROT_NONE = 0x0
comptime PROT_READ = 0x1
comptime PROT_WRITE = 0x2
comptime PROT_EXEC = 0x4

comptime MADV_NORMAL = 0
comptime MADV_RANDOM = 1
comptime MADV_SEQUENTIAL = 2
comptime MADV_WILLNEED = 3
comptime MADV_DONTNEED = 4
comptime MADV_FREE = 8
comptime MADV_REMOVE = 9
comptime MADV_DONTFORK = 10
comptime MADV_DOFORK = 11
comptime MADV_MERGEABLE = 12
comptime MADV_UNMERGEABLE = 13
comptime MADV_HUGEPAGE = 14
comptime MADV_NOHUGEPAGE = 15
comptime MADV_DONTDUMP = 16
comptime MADV_DODUMP = 17
comptime MADV_WIPEONFORK = 18
comptime MADV_KEEPONFORK = 19
comptime MADV_COLD = 20
comptime MADV_PAGEOUT = 21
comptime MADV_POPULATE_READ = 22
comptime MADV_POPULATE_WRITE = 23
comptime MADV_DONTNEED_LOCKED = 24
comptime MADV_COLLAPSE = 25
comptime MADV_HWPOISON = 100
comptime MADV_SOFT_OFFLINE = 101

# Kernel timespec
@fieldwise_init
struct __kernel_timespec(ImplicitlyCopyable, Movable):
    var tv_sec: c_longlong
    var tv_nsec: c_longlong

# Signal set (simple alias on LP64 Linux)
comptime sigset_t = c_ulong

# File descriptor flags
comptime O_NONBLOCK = 2048
comptime O_CLOEXEC = 524288

# fcntl constants
comptime F_GETFL = 3
comptime F_SETFL = 4
