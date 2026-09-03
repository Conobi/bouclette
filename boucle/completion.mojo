"""Completion-based I/O — submit work, get notified when done.

Best for:
  - Bulk data transfer (file serving, streaming)
  - Batching many operations (database engines, storage)
  - Workloads where cancellation is rare

The kernel performs I/O on your behalf. You hand over buffer
ownership and get it back on completion.

See `boucle.readiness` for the alternative model.
"""

from boucle.handle import RawHandle
from boucle.proactor.completion import Completion, CompletionFn
from boucle.proactor.loop import EventLoop
from boucle.drivers import _CompletionDriver
from boucle.drivers.backend import Backend
from std.memory import Pointer


# ── Opaque CompletionLoop ─────────────────────────────────────────────────────


struct CompletionLoop(Movable):
    """Opaque completion event loop. Backend resolved at comptime.

    Wraps an EventLoop with the platform-appropriate completion driver
    (io_uring on Linux, IOCP on Windows, kqueue emulation on macOS).
    Consumers interact through portable IoDriver methods — the concrete
    backend is never visible.
    """

    var _inner: EventLoop[_CompletionDriver]

    def __init__(out self, sq_entries: UInt32 = 64, *, backend: Backend = Backend.AUTO) raises:
        """Construct a CompletionLoop with the given SQ capacity.

        Args:
            sq_entries: Number of submission queue entries (default 64).
            backend: I/O backend — AUTO probes for io_uring then falls
                     back to epoll. IO_URING requires io_uring. EPOLL
                     forces epoll even when io_uring is available.
        """
        self._inner = EventLoop[_CompletionDriver](
            _CompletionDriver(sq_entries=sq_entries, backend=backend)
        )

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._inner = move._inner^

    def __deinit__(deinit self):
        """Destroy the event loop and its underlying driver."""
        self._inner^.__deinit__()

    # ── IoDriver delegation ───────────────────────────────────────────────

    def tick(mut self, wait: Bool) raises -> Int:
        """Submit pending SQEs and dispatch completed operations.

        Args:
            wait: If True, block until at least one completion arrives.
                  If False, return immediately after dispatching any
                  already-available completions.

        Returns:
            The number of dispatched CQEs.
        """
        return self._inner.driver.tick(wait)

    def submit_nop(
        mut self, c: Pointer[Completion, MutUntrackedOrigin]
    ) raises:
        """Queue a no-op operation.

        Args:
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_nop(c)

    def submit_connect(
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
        self._inner.driver.submit_connect(fd, addr, addr_len, c)

    def submit_timeout(
        mut self,
        ts: Pointer[NoneType, ImmStaticOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a timeout (kernel timer).

        Args:
            ts: Opaque pointer to a platform-specific timespec.
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_timeout(ts, c)

    def submit_cancel(
        mut self,
        target: Pointer[Completion, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Args:
            target: Pointer to the Completion of the op to cancel.
            c: Pointer to the Completion token for the cancel itself.
        """
        self._inner.driver.submit_cancel(target, c)

    def submit_accept(
        mut self,
        fd: RawHandle,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an accept on listening socket `fd`.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_accept(fd, c)

    def submit_recv(
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
        self._inner.driver.submit_recv(fd, buf, len, c)

    def submit_send(
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
        self._inner.driver.submit_send(fd, buf, len, c)

    def submit_recvmsg(
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
        self._inner.driver.submit_recvmsg(fd, msg, c)

    def submit_sendmsg(
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
        self._inner.driver.submit_sendmsg(fd, msg, c)

    def sq_space(mut self) -> Int:
        """Return the number of available submission queue slots.

        Returns:
            The number of SQ entries currently available for submission.
        """
        return self._inner.driver.sq_space()

    def backend(self) -> Backend:
        """Return which kernel I/O mechanism is active."""
        return self._inner.driver.backend()

    # ── EventLoop convenience methods ─────────────────────────────────────

    def run_once(mut self) raises:
        """Block until at least one completion fires, then dispatch all ready."""
        self._inner.run_once()

    def try_poll(mut self) raises:
        """Non-blocking: dispatch any ready completions, return immediately."""
        self._inner.try_poll()

    def run(mut self) raises:
        """Run until stop() is called."""
        self._inner.run()

    def stop(mut self):
        """Signal the loop to exit after the current tick."""
        self._inner.stop()
