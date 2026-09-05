"""The one place where the public layer meets a concrete OS.

Everything above `boucle.socle` — `boucle.error`, `boucle.handle`,
`boucle.ctypes`, `boucle.watch` — imports its OS-level names from here
and never from `boucle.socle.<os>`. Porting boucle to a second OS is
then an edit of this file plus a new `boucle.socle.<os>` package, not a
sweep through every portable module.

`boucle.drivers` is exempt: its members are named after the mechanism
they drive (`io_uring.mojo`, `epoll.mojo`) and are selected at comptime
by `AutoDriver`, so they legitimately import their own backend directly.

Mojo 1.0.0 rejects `comptime if` outside a function body, so the OS
cannot be chosen by a conditional import; the selection is expressed by
which module the `from` clauses below name. `platform_name` carries the
comptime answer for code that needs to branch, and `boucle.socle`
exports `is_linux` / `is_darwin` / `is_windows` for guards inside
functions (see `AutoDriver.__init__`).

The names re-exported here are the vocabulary the public layer speaks:
`Errno` and the errno constants it reasons about, the raw-handle
primitives, the C scalar aliases, the sockaddr layouts and socket
syscalls `boucle.net` is built on, and the coroutine stack backend.
Widen the set on demand rather than mirroring a whole platform package.

Not every name is equally portable, and the difference matters to
whoever writes the second backend. Each section below is tagged:

- **portable** — POSIX or otherwise identical in shape on every target
  OS. A second backend supplies the same name and the callers above are
  unaffected. Numeric constants may still differ in *value* (`O_CLOEXEC`
  is 0o2000000 on Linux and 0x1000000 on macOS); only the *name* and its
  meaning are guaranteed, which is exactly why callers must not inline
  the literals.
- **needs a per-OS equivalent** — Linux-shaped, with no drop-in twin
  elsewhere. Porting means writing an adapter under
  `boucle.socle.<os>` that presents the same signature, not a rename.
  The known ones are `_raw_accept4` (`accept4(2)` is Linux/BSD; macOS
  has only `accept(2)` and needs a follow-up `fcntl` to apply
  `O_NONBLOCK`/`O_CLOEXEC`), `MSG_NOSIGNAL` (macOS suppresses `SIGPIPE`
  with the `SO_NOSIGPIPE` socket option instead, so the flag has to move
  from the per-call argument to socket setup), `SO_REUSEPORT`
  (present on BSD/macOS but with load-balancing semantics Linux only
  gained in 3.9 — verify before relying on it), `SOL_IP` and `SOL_IPV6`
  (Linux spellings of the IPv4/IPv6 option levels; POSIX, BSD and macOS
  spell these `IPPROTO_IP`/`IPPROTO_IPV6` instead, and macOS has no
  `SOL_IP` at all — though `SOL_IPV6 == IPPROTO_IPV6` numerically, so a
  second backend can alias one to the other), and `IP_RECVTOS` (a
  BSD/Linux extension, not POSIX; macOS numbers it 27, FreeBSD 68,
  not the Linux value).
- **portable by contract** — not identical in nature across platforms,
  but boucle adopts one backend's encoding as the library-wide
  convention and requires every other backend to reproduce it, so
  callers see one shape regardless of which kernel mechanism drives the
  loop. The completion flag bits (`IORING_CQE_BUFFER_SHIFT`,
  `IORING_CQE_F_BUFFER`, `IORING_CQE_F_MORE`) are the current example:
  io_uring's layout is the contract, and the epoll completion driver
  emits the same bits for its emulated multishot deliveries rather than
  inventing its own.
"""

from boucle.socle import is_linux, is_darwin, is_windows

comptime platform_name: StaticString = "linux" if is_linux else (
    "darwin" if is_darwin else "windows"
)
"""The OS this build targets, for diagnostics and comptime branching."""

# --- Errno vocabulary -------------------------------------------------

from boucle.socle.linux.errno import Errno

from boucle.socle.linux.raw import (
    EACCES,
    EADDRINUSE,
    EADDRNOTAVAIL,
    EAFNOSUPPORT,
    EAGAIN,
    EBADF,
    ECANCELED,
    ECONNABORTED,
    ECONNREFUSED,
    ECONNRESET,
    EEXIST,
    EHOSTUNREACH,
    EINPROGRESS,
    EINTR,
    EINVAL,
    ENETUNREACH,
    ENOENT,
    ENOMEM,
    ENOSYS,
    ENOTCONN,
    EPERM,
    EPIPE,
    ETIMEDOUT,
)

# --- Completion flag encoding (portable by contract) -------------------
#
# The flags a completion callback receives use io_uring's CQE layout on
# every backend: the epoll completion driver emits the same bits for its
# emulated multishot deliveries. A second OS backend keeps the encoding
# and maps its native flags onto it, so these three names are the
# contract, not a Linux detail.

from boucle.socle.linux.raw import (
    IORING_CQE_BUFFER_SHIFT,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
)

# --- Raw handles ------------------------------------------------------

from boucle.socle.linux.fd import (
    UnsafeFd,
    close,
    close_unchecked,
    unsafe_fd_as_arg,
)

# --- C scalar aliases -------------------------------------------------

from boucle.socle.linux.raw.ctypes import (
    c_void,
    c_char,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_size_t,
    c_ssize_t,
)

# --- Socket addresses (portable) --------------------------------------
#
# `sockaddr_in` / `sockaddr_in6` / `socklen_t` / `__be32` are the POSIX
# wire layouts; every target OS agrees on them byte for byte, because
# the kernel is not the only party reading these structs. `_to_be` is
# pure host-order/network-order byte swapping with no OS in it at all.

from boucle.socle.linux.raw import (
    __be32,
    sockaddr_in,
    sockaddr_in6,
    socklen_t,
)

# --- Message headers (needs a per-OS equivalent) ----------------------
#
# `iovec` is POSIX and identical everywhere. `msghdr` and `cmsghdr` are
# POSIX in name but not in field width: Linux LP64 uses `size_t` for
# `msg_iovlen`, `msg_controllen` and `cmsg_len`, macOS uses `int` /
# `socklen_t`. The portable message layer (`boucle.net.message`, added
# with the message futures) and `boucle.watch` build these structs
# field by field, so a second backend supplies its own layouts under
# the same names.

from boucle.socle.linux.raw import (
    cmsghdr,
    iovec,
    msghdr,
)

from boucle.socle.linux.raw.utils import _to_be

# --- Socket syscalls (portable, except `_raw_accept4`) ----------------
#
# Thin wrappers that raise on a negative return; `boucle.net.socket`
# re-raises each as an `IOError`. All are POSIX calls with identical
# signatures elsewhere — except `_raw_accept4`, which needs a per-OS
# equivalent (see the module docstring).

from boucle.socle.linux.net.syscalls import (
    _bind,
    _connect,
    _fcntl_getfl,
    _fcntl_setfl,
    _getpeername,
    _getsockname,
    _getsockopt_int,
    _listen,
    _raw_accept4,
    _recv,
    _recvfrom,
    _send,
    _sendto,
    _setsockopt,
    _setsockopt_timeval,
    _shutdown,
    _socket,
)

# --- Socket options (portable names, per-OS values) -------------------
#
# `boucle.net.options` hardcodes the portable enums and asserts them
# against these at compile time, so a second backend whose values differ
# fails the build instead of silently misconfiguring a socket.
#
# `MSG_NOSIGNAL`, `SO_REUSEPORT`, `SOL_IP`, `SOL_IPV6` and `IP_RECVTOS`
# need a per-OS equivalent (see the module docstring); the rest are
# POSIX. `SOL_IPV6 == IPPROTO_IPV6`, so a second backend can alias one
# to the other.

from boucle.socle.linux.raw import (
    AF_INET,
    AF_INET6,
    AF_UNIX,
    AF_UNSPEC,
    IPPROTO_IPV6,
    IPV6_RECVTCLASS,
    IPV6_TCLASS,
    IPV6_V6ONLY,
    IP_RECVTOS,
    IP_TOS,
    MSG_CTRUNC,
    MSG_NOSIGNAL,
    MSG_TRUNC,
    O_CLOEXEC,
    O_NONBLOCK,
    SOCK_DGRAM,
    SOCK_STREAM,
    SOL_IP,
    SOL_IPV6,
    SOL_SOCKET,
    SO_ERROR,
    SO_RCVTIMEO,
    SO_REUSEADDR,
    SO_REUSEPORT,
    SO_SNDTIMEO,
)

# --- Coroutine stacks (portable) --------------------------------------
#
# `ucontext_t` and `swapcontext(3)` are POSIX. macOS ships them (marked
# obsolescent, and `_XOPEN_SOURCE` must be defined); Windows has no
# equivalent and would need a fibers-based backend under
# `boucle.socle.windows`.

from boucle.socle.linux.ucontext_stack import _UcontextStack
