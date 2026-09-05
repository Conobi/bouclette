"""Raw completion loop — the escape hatch under `WatchLoop`.

The kernel performs I/O on your behalf: you hand over a buffer and a
caller-owned `Completion` and get them back when the operation is done.

This is the driver interface, not the user-facing model. Every method
takes raw pointers and none of them returns a typed result, so keeping
the operation state alive until its completion fires is entirely on the
caller. Reach for `boucle.WatchLoop` instead; use this only when you
need an operation the futures do not expose yet.
"""

from boucle.handle import RawHandle
from boucle.proactor.completion import Completion, CompletionFn
from boucle.proactor.loop import EventLoop
from boucle.drivers import _CompletionDriver
from boucle.drivers.backend import Backend
from boucle.drivers.feature import DriverFeature
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

    def __init__(
        out self, *, capacity: Int = 64, backend: Backend = Backend.AUTO
    ) raises:
        """Construct a CompletionLoop with the given capacity hint.

        Args:
            capacity: How many operations the loop should be ready to
                      hold at once (default 64). A hint — the backend
                      may round it up, and exceeding it is not an error.
            backend: I/O backend — AUTO probes for io_uring then falls
                     back to epoll. IO_URING requires io_uring. EPOLL
                     forces epoll even when io_uring is available.
        """
        self._inner = EventLoop[_CompletionDriver](
            _CompletionDriver(capacity=capacity, backend=backend)
        )

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._inner = move._inner^

    def __deinit__(deinit self):
        """Destroy the event loop and its underlying driver."""
        self._inner^.__deinit__()

    # ── IoDriver delegation ───────────────────────────────────────────────

    def tick(mut self, wait: Bool) raises -> Int:
        """Submit pending operations and dispatch completed operations.

        Args:
            wait: If True, block until at least one completion arrives.
                  If False, return immediately after dispatching any
                  already-available completions.

        Returns:
            The number of completed operations.
        """
        return self._inner.driver.tick(wait)

    def nop(
        mut self, c: Pointer[Completion, MutUntrackedOrigin]
    ) raises:
        """Queue a no-op operation.

        Args:
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.nop(c)

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
        self._inner.driver.connect(fd, addr, addr_len, c)

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
        self._inner.driver.timeout(ts, c)

    def cancel(
        mut self,
        target: Pointer[Completion, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Args:
            target: Pointer to the Completion of the op to cancel.
            c: Pointer to the Completion token for the cancel itself.
        """
        self._inner.driver.cancel(target, c)

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
        self._inner.driver.accept(fd, c)

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
        self._inner.driver.recv(fd, buf, len, c)

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
        self._inner.driver.send(fd, buf, len, c)

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
        self._inner.driver.recvmsg(fd, msg, c)

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
        self._inner.driver.sendmsg(fd, msg, c)

    def backend(self) -> Backend:
        """Return which kernel I/O mechanism is active."""
        return self._inner.driver.backend()

    def supports(self, feature: DriverFeature) -> Bool:
        """Return whether the active driver provides `feature`.

        Args:
            feature: The capability to query.

        Returns:
            The driver's answer; True on epoll, kernel-dependent on io_uring.
        """
        return self._inner.driver.supports(feature)

    # ── EventLoop convenience methods ─────────────────────────────────────

    def run_once(mut self) raises:
        """Run one blocking tick.

        Waits for at least one completion, then dispatches every
        completion that is ready by the time it wakes up. There is no
        timeout: the driver can only be told to wait or not to wait, so
        a bounded wait is expressed by submitting a timeout operation.
        """
        self._inner.run_once()

    def poll(mut self) raises:
        """Run one non-blocking tick.

        Dispatches the completions that are already available and
        returns, even when there are none.
        """
        self._inner.poll()

    def run_forever(mut self) raises:
        """Run blocking ticks until stop() is called.

        Unlike `WatchLoop.run()`, this does not return when the loop
        runs out of work — a callback (or another thread) must call
        `stop()`.
        """
        self._inner.run_forever()

    def stop(mut self):
        """Signal the loop to exit after the current tick."""
        self._inner.stop()
