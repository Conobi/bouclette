"""Platform-agnostic I/O driver trait.

Defines the interface that platform-specific I/O backends must
implement. Each method either submits work to the kernel or
dispatches completed operations via their Completion callbacks.

All pointer parameters use opaque types (NoneType) so the trait
carries no platform-specific imports. Concrete drivers cast
internally to their platform types (e.g. c_void, msghdr).
"""

from std.memory import Pointer

from boucle.proactor.completion import Completion
from boucle.handle import RawHandle
from boucle.interest import Interest
from boucle.token import Token
from boucle.drivers.readiness_event import ReadinessEvent


trait IoDriver(Movable):
    """Platform I/O backend abstraction.

    Implementors wrap a kernel async I/O mechanism (e.g. io_uring,
    kqueue, IOCP) and expose a uniform submit/tick interface consumed
    by the proactor event loop.
    """

    def __deinit__(deinit self):
        """Release all resources held by this driver."""
        ...

    def tick(mut self, wait: Bool) raises:
        """Submit pending SQEs and dispatch completed operations.

        Args:
            wait: If True, block until at least one completion arrives.
                  If False, return immediately after dispatching any
                  already-available completions.
        """
        ...

    def submit_nop(
        mut self, c: Pointer[Completion, MutUntrackedOrigin]
    ) raises:
        """Queue a no-op operation.

        Args:
            c: Pointer to the caller-owned Completion token. Stored as
               SQE user_data; fired on CQE arrival.
        """
        ...

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
            addr: Pointer to the sockaddr structure (must remain valid
                  until completion fires).
            addr_len: Size in bytes of the sockaddr structure.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def submit_timeout(
        mut self,
        ts: Pointer[NoneType, ImmStaticOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a timeout (kernel timer).

        Args:
            ts: Opaque pointer to a platform-specific timespec (e.g.
                16-byte kernel_timespec on Linux). Must remain valid
                until completion fires.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def submit_cancel(
        mut self,
        target: Pointer[Completion, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Matches the target by its Completion pointer (stored as
        user_data in the original SQE). The cancel itself produces
        a CQE on `c`; the cancelled target also produces a CQE with
        result == -ECANCELED if it was still in flight.

        Args:
            target: Pointer to the Completion of the operation to cancel.
            c: Pointer to the Completion token for the cancel operation
               itself.
        """
        ...

    def submit_accept(
        mut self,
        fd: RawHandle,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an accept on listening socket `fd`.

        The CQE result is the accepted file descriptor (>= 0) on
        success, or a negative errno on failure.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        ...

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
            buf: Buffer to receive into. Must remain valid until CQE fires.
            len: Maximum bytes to receive.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def submit_send(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a send on socket `fd` from `buf`.

        Caller guarantees `buf` remains valid and unmodified until
        the corresponding CQE fires.

        Args:
            fd: The socket file descriptor.
            buf: Data to send. Must remain valid until CQE fires.
            len: Number of bytes to send.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def submit_recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a recvmsg on socket `fd`.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to a platform-specific message header
                 (e.g. msghdr on Linux). Must remain valid until CQE
                 fires.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def submit_sendmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a sendmsg on socket `fd`.

        Caller guarantees `msg` and all referenced buffers remain valid
        and unmodified until the corresponding CQE fires.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to a platform-specific message header
                 (e.g. msghdr on Linux).
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def sq_space(mut self) -> Int:
        """Return the number of available submission queue slots.

        Callers use this to verify sufficient capacity before
        submitting multi-SQE atomic operations (e.g. connect +
        timeout that must both fit or neither is queued).

        Returns:
            The number of SQ entries currently available for submission.
        """
        ...


trait ReadinessDriver(Movable):
    """Platform readiness-notification backend abstraction.

    Implementors wrap a kernel readiness mechanism (e.g. epoll,
    kqueue) and expose a uniform register/poll interface consumed
    by the readiness event loop.
    """

    def __deinit__(deinit self):
        """Release all resources held by this driver."""
        ...

    def register(
        mut self, fd: RawHandle, interest: Interest, token: Token
    ) raises:
        """Add a file descriptor to the interest set.

        Args:
            fd: The file descriptor to monitor.
            interest: Which I/O events to watch for.
            token: Opaque token returned in ReadinessEvent on notification.
        """
        ...

    def modify(
        mut self, fd: RawHandle, interest: Interest, token: Token
    ) raises:
        """Modify the interest flags for a registered file descriptor.

        Args:
            fd: The registered file descriptor.
            interest: New set of I/O events to watch for.
            token: New opaque token for subsequent notifications.
        """
        ...

    def deregister(mut self, fd: RawHandle) raises:
        """Remove a file descriptor from the interest set.

        Args:
            fd: The registered file descriptor to remove.
        """
        ...

    def poll(
        mut self, *, timeout_ms: Int32 = -1
    ) raises -> List[ReadinessEvent]:
        """Wait for readiness events and return them.

        Blocks until at least one event is ready or the timeout
        expires. A timeout of -1 blocks indefinitely; 0 returns
        immediately.

        Args:
            timeout_ms: Maximum milliseconds to wait (-1 = infinite,
                        0 = non-blocking).

        Returns:
            List of readiness events from this poll cycle.
        """
        ...
