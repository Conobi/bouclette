"""Linux backend facade — high-level Linux surface.

Re-exports the high-level Linux symbols so consumers under `boucle.*`
(and the `_sys/linux/{io_uring,epoll,net}/` subpackages) spell
`from boucle.socle.linux import close, mmap, Errno` instead of reaching
into `boucle.socle.linux.fd` + `boucle.socle.linux.mm` +
`boucle.socle.linux.errno` separately.

This is the symmetric counterpart of `boucle.socle.linux.raw` introduced
in the previous task: `raw` re-exports the arch-specific syscall stubs
under `raw/x86_64/`; this facade re-exports the typed wrappers built on
top of them.

Subpackages (`io_uring`, `epoll`, `net`) are not re-exported here —
callers address them directly (e.g.
`from boucle.socle.linux.io_uring import ...`). The `utils.mojo` helpers
are all underscore-prefixed and intentionally not re-exported.
"""

# ── File descriptor ops (fd.mojo) ────────────────────────────────────
from boucle.socle.linux.fd import (
    UnsafeFd,
    NoFd,
    unsafe_fd_as_arg,
    close,
    close_unchecked,
    dup,
)

# ── Memory mapping (mm.mojo) ─────────────────────────────────────────
from boucle.socle.linux.mm import (
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
from boucle.socle.linux.errno import (
    Errno,
    unsafe_decode_result,
    unsafe_decode_ptr,
    unsafe_decode_none,
)

# ── ucontext FFI wrappers (ucontext.mojo) ────────────────────────────
from boucle.socle.linux.ucontext import (
    alloc_ucontext,
    free_ucontext,
    uc_getcontext,
    uc_swapcontext,
    uc_swapcontext_unchecked,
    setup_context,
)
