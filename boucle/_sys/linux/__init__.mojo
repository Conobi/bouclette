"""Linux backend facade — high-level Linux surface.

Re-exports the high-level Linux symbols so consumers under `boucle.*`
(and the `_sys/linux/{io_uring,epoll,net}/` subpackages) spell
`from boucle._sys.linux import close, mmap, Errno` instead of reaching
into `boucle._sys.linux.fd` + `boucle._sys.linux.mm` +
`boucle._sys.linux.errno` separately.

This is the symmetric counterpart of `boucle._sys.linux.raw` introduced
in the previous task: `raw` re-exports the arch-specific syscall stubs
under `raw/x86_64/`; this facade re-exports the typed wrappers built on
top of them.

Subpackages (`io_uring`, `epoll`, `net`) are not re-exported here —
callers address them directly (e.g.
`from boucle._sys.linux.io_uring import ...`). The `utils.mojo` helpers
are all underscore-prefixed and intentionally not re-exported.
"""

# ── File descriptor ops (fd.mojo) ────────────────────────────────────
from boucle._sys.linux.fd import (
    UnsafeFd,
    NoFd,
    unsafe_fd_as_arg,
    close,
    close_unchecked,
    dup,
)

# ── Memory mapping (mm.mojo) ─────────────────────────────────────────
from boucle._sys.linux.mm import (
    mmap,
    mmap_anonymous,
    munmap,
    madvise,
    mprotect,
    MapFlags,
    ProtFlags,
    Advice,
)

# ── Errno + result decoders (errno.mojo) ─────────────────────────────
from boucle._sys.linux.errno import (
    Errno,
    unsafe_decode_result,
    unsafe_decode_ptr,
    unsafe_decode_none,
)

# ── ucontext FFI wrappers (ucontext.mojo) ────────────────────────────
from boucle._sys.linux.ucontext import (
    alloc_ucontext,
    free_ucontext,
    uc_getcontext,
    uc_swapcontext,
    uc_swapcontext_unchecked,
    setup_context,
)
