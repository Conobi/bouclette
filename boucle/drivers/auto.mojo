"""Auto-selecting completion driver with io_uring-to-epoll fallback.

Probes for io_uring support at construction time and falls back to
EpollCompletionDriver when unavailable. Implements IoDriver by
delegating every method to whichever backend is active. The backend
branch is perfectly predicted after init — essentially zero cost.
"""

from std.collections import Optional
from std.memory import Pointer

from boucle.proactor.completion import Completion
from boucle.handle import RawHandle
from boucle.drivers.driver import IoDriver
from boucle.drivers.backend import Backend
from boucle.drivers.io_uring import IoUringDriver
from boucle.drivers.epoll_completion import EpollCompletionDriver
from boucle.socle import is_linux


struct AutoDriver(IoDriver):
    """IoDriver that probes for io_uring and falls back to epoll.

    At construction, attempts to create an IoUringDriver. If the
    io_uring syscalls are unavailable (ENOSYS on older kernels or
    in restricted containers), falls back to EpollCompletionDriver.

    The caller can force a specific backend via the `backend`
    keyword argument (Backend.IO_URING or Backend.EPOLL). With
    Backend.AUTO (the default), the probe runs normally.

    After init, every IoDriver method delegates to the active
    backend via a single branch on `_backend`. This branch is
    perfectly predicted by the CPU after the first call.
    """

    var _backend: Backend
    var _uring: Optional[IoUringDriver]
    var _epoll: Optional[EpollCompletionDriver]

    def __init__(
        out self,
        *,
        capacity: Int = 64,
        backend: Backend = Backend.AUTO,
    ) raises:
        """Probe for io_uring and construct the appropriate backend.

        Args:
            capacity: How many operations the driver should be ready to
                      hold at once (default 64). A hint, forwarded to
                      whichever backend wins the probe.
            backend: Force a specific backend. Backend.AUTO (default)
                     probes for io_uring first; Backend.IO_URING
                     requires io_uring or raises; Backend.EPOLL
                     skips probing entirely.
        """
        comptime if not is_linux:
            if backend is Backend.IO_URING or backend is Backend.EPOLL:
                raise "Backend.IO_URING and Backend.EPOLL require Linux"

        if backend is not Backend.EPOLL:
            try:
                self._uring = IoUringDriver(capacity=capacity)
                self._epoll = None
                self._backend = Backend.IO_URING
                return
            except:
                if backend is Backend.IO_URING:
                    raise "io_uring unavailable (ENOSYS)"
        self._uring = None
        self._epoll = EpollCompletionDriver(capacity=capacity)
        self._backend = Backend.EPOLL

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._backend = move._backend
        self._uring = move._uring^
        self._epoll = move._epoll^

    def __deinit__(deinit self):
        """Release resources held by the active backend only.

        The inactive Optional is None so its destructor is a no-op.
        The active Optional contains the driver whose destructor
        releases all kernel resources.
        """
        _ = self._uring^
        _ = self._epoll^

    def tick(mut self, wait: Bool) raises -> Int:
        """Submit pending work and dispatch completed operations.

        Args:
            wait: If True, block until at least one completion arrives.
                  If False, return immediately after dispatching any
                  already-available completions.

        Returns:
            The number of dispatched completions.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().tick(wait)
        return self._epoll.value().tick(wait)

    def nop(
        mut self, c: Pointer[Completion, MutUntrackedOrigin]
    ) raises:
        """Queue a no-op operation.

        Args:
            c: Pointer to the caller-owned Completion token.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().nop(c)
        return self._epoll.value().nop(c)

    def connect(
        mut self,
        fd: RawHandle,
        addr: Pointer[UInt8, ImmStaticOrigin],
        addr_len: UInt64,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a connect on socket `fd` to the given address.

        Args:
            fd: The socket file descriptor.
            addr: Pointer to the sockaddr structure.
            addr_len: Size in bytes of the sockaddr structure.
            c: Pointer to the caller-owned Completion token.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().connect(fd, addr, addr_len, c)
        return self._epoll.value().connect(fd, addr, addr_len, c)

    def timeout(
        mut self,
        ts: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a timeout (kernel timer).

        Args:
            ts: Opaque pointer to a platform-specific timespec. Caller
                must keep it alive until the completion fires.
            c: Pointer to the caller-owned Completion token.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().timeout(ts, c)
        return self._epoll.value().timeout(ts, c)

    def cancel(
        mut self,
        target: Pointer[Completion, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Args:
            target: Pointer to the Completion of the operation to cancel.
            c: Pointer to the Completion token for the cancel itself.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().cancel(target, c)
        return self._epoll.value().cancel(target, c)

    def accept(
        mut self,
        fd: RawHandle,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an accept on listening socket `fd`.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().accept(fd, c)
        return self._epoll.value().accept(fd, c)

    def recv(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a recv from socket `fd` into `buf`.

        Args:
            fd: The socket file descriptor.
            buf: Buffer to receive into.
            len: Maximum bytes to receive.
            c: Pointer to the caller-owned Completion token.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().recv(fd, buf, len, c)
        return self._epoll.value().recv(fd, buf, len, c)

    def send(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a send on socket `fd` from `buf`.

        Args:
            fd: The socket file descriptor.
            buf: Data to send.
            len: Number of bytes to send.
            c: Pointer to the caller-owned Completion token.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().send(fd, buf, len, c)
        return self._epoll.value().send(fd, buf, len, c)

    def recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a recvmsg on socket `fd`.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to a platform-specific message header.
            c: Pointer to the caller-owned Completion token.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().recvmsg(fd, msg, c)
        return self._epoll.value().recvmsg(fd, msg, c)

    def sendmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a sendmsg on socket `fd`.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to a platform-specific message header.
            c: Pointer to the caller-owned Completion token.
        """
        if self._backend is Backend.IO_URING:
            return self._uring.value().sendmsg(fd, msg, c)
        return self._epoll.value().sendmsg(fd, msg, c)

    def backend(self) -> Backend:
        """Return which kernel I/O mechanism this driver uses."""
        return self._backend
