"""Pthread struct sizes, eventfd flags, and signal constants.

Sizes are for glibc on LP64 Linux (x86_64, aarch64). Verified against
`sizeof(pthread_mutex_t)` / `sizeof(pthread_cond_t)` / `sizeof(pthread_t)`
on x86_64 glibc; aarch64 glibc uses the same LP64 layout for these opaque
types.
"""

from boucle.socle.linux.raw.utils import _pick_int


# pthread_mutex_t size in bytes (glibc LP64).
comptime PTHREAD_MUTEX_SIZE = _pick_int[40, 40]()
# pthread_cond_t size in bytes (glibc LP64).
comptime PTHREAD_COND_SIZE = _pick_int[48, 48]()
# pthread_t size in bytes (LP64).
comptime PTHREAD_T_SIZE = 8

# eventfd flags.
comptime EFD_CLOEXEC = 524288  # O_CLOEXEC
comptime EFD_NONBLOCK = 2048  # O_NONBLOCK

# Signal mask operation for pthread_sigmask.
comptime SIG_SETMASK = 2
# glibc's sigset_t size in bytes (LP64 Linux): 1024 bits, stored as 16
# `unsigned long`s. This is the ABI `pthread_sigmask` (a glibc symbol,
# not the raw `rt_sigprocmask` syscall) expects for both its `set` and
# `oldset` arguments; passing a bare 8-byte word here would make glibc
# read/write 120 bytes past the buffer on every call.
comptime SIGSET_SIZE = 128
