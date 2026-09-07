"""Platform-agnostic I/O driver trait.

Defines the interface that platform-specific I/O backends must
implement. Each method either queues operations for the kernel or
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
from boucle.drivers.backend import Backend
from boucle.drivers.feature import DriverFeature
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

    def tick(mut self, wait: Bool, timeout_ms: Int = -1) raises -> Int:
        """Submit pending operations and dispatch completed operations.

        Args:
            wait: If True, block until at least one completion arrives
                  or `timeout_ms` has passed. If False, return
                  immediately after dispatching any already-available
                  completions; `timeout_ms` is then ignored.
            timeout_ms: Upper bound on the wait in milliseconds. -1
                        waits without limit; 0 polls.

        Returns:
            The number of completed operations the caller can observe.
            Bookkeeping completions the driver submits for itself are
            not counted.
        """
        ...

    def nop(
        mut self, c: Pointer[Completion, MutUntrackedOrigin]
    ) raises:
        """Queue a no-op operation.

        Args:
            c: Pointer to the caller-owned Completion token. Stored as
               operation user_data; fired on completion arrival.
        """
        ...

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
            addr: Pointer to the sockaddr structure (must remain valid
                  until completion fires).
            addr_len: Size in bytes of the sockaddr structure.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def timeout(
        mut self,
        ts: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a timeout (kernel timer).

        Args:
            ts: Opaque pointer to a platform-specific timespec (e.g.
                16-byte kernel_timespec on Linux). Caller must keep
                the timespec alive until the completion fires.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def cancel(
        mut self,
        target: Pointer[Completion, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Matches the target by its Completion pointer (stored as
        user_data in the original operation). The cancel itself produces
        a completion on `c`; the cancelled target also produces a completion
        with result == -ECANCELED if it was still in flight.

        Args:
            target: Pointer to the Completion of the operation to cancel.
            c: Pointer to the Completion token for the cancel operation
               itself.
        """
        ...

    def accept(
        mut self,
        fd: RawHandle,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an accept on listening socket `fd`.

        The completion result is the accepted file descriptor (>= 0) on
        success, or a negative errno on failure.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        ...

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
            buf: Buffer to receive into. Must remain valid until completion fires.
            len: Maximum bytes to receive.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def send(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a send on socket `fd` from `buf`.

        Caller guarantees `buf` remains valid and unmodified until
        the corresponding completion fires.

        Args:
            fd: The socket file descriptor.
            buf: Data to send. Must remain valid until completion fires.
            len: Number of bytes to send.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def read(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        offset: UInt64,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an async pread.

        Args:
            fd: File descriptor opened for reading.
            buf: Destination buffer (must remain valid until completion).
            len: Maximum bytes to read.
            offset: File offset in bytes.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def write(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        offset: UInt64,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an async pwrite.

        Args:
            fd: File descriptor opened for writing.
            buf: Source buffer (must remain valid until completion).
            len: Number of bytes to write.
            offset: File offset in bytes.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def fsync(
        mut self,
        fd: RawHandle,
        datasync: Bool,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an async fsync or fdatasync.

        Args:
            fd: File descriptor.
            datasync: If True, fdatasync semantics.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
        flags: UInt32 = 0,
    ) raises:
        """Queue a recvmsg on socket `fd`.

        `flags` are the caller's `recvmsg(2)` flags, passed to the kernel
        as given (a driver may add what its own mechanism needs, such as
        MSG_DONTWAIT). The caller decides per socket: MSG_TRUNC makes a
        datagram socket report the full datagram length, but makes a
        stream socket discard the bytes instead of copying them.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to a platform-specific message header
                 (e.g. msghdr on Linux). Must remain valid until completion
                 fires.
            c: Pointer to the caller-owned Completion token.
            flags: `recvmsg(2)` flags to pass through; 0 for none.
        """
        ...

    def sendmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a sendmsg on socket `fd`.

        Caller guarantees `msg` and all referenced buffers remain valid
        and unmodified until the corresponding completion fires.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to a platform-specific message header
                 (e.g. msghdr on Linux).
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def multishot_recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        group_id: UInt16,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a multishot recvmsg that receives into provided buffers.

        One completion fires per datagram: result is the number of bytes
        written into the selected buffer (16-byte delivery header, name
        slot, control area, payload), flags carry the buffer id
        (`buffer_id`) and whether the operation is still armed
        (`has_more`). The operation ends with a completion lacking the
        more flag: -ENOBUFS when the group is empty, -ECANCELED on
        cancel, or another errno. A zero-length datagram may also be
        terminal: io_uring ends the operation on it with no more flag
        and a positive result (the header, name and control capacities
        with an empty payload), while the epoll emulation delivers it
        and stays armed. A socket that is readable forever without
        yielding a datagram (shut down for reading, or holding a pending
        error) diverges the other way: the epoll emulation ends the
        operation with the pending `SO_ERROR`, else ECONNRESET, else
        EIO, while io_uring fires nothing and the operation stays armed
        until it is cancelled. Callers must treat any completion without
        `has_more` as the end, whatever its result. On a forced io_uring backend whose kernel
        lacks multishot recvmsg (before 6.0) the call raises EOPNOTSUPP.

        Args:
            fd: The datagram socket.
            msg: Opaque pointer to a platform msghdr template whose
                 `msg_namelen` and `msg_controllen` set the name and
                 control capacities. Must remain valid until the
                 terminal completion fires.
            group_id: A group registered with `register_buffer_group`.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def register_buffer_group(
        mut self,
        base: Pointer[UInt8, MutUntrackedOrigin],
        size: UInt32,
        count: Int,
        group_id: UInt16,
    ) raises:
        """Register `count` contiguous buffers of `size` bytes as a group.

        Buffer `i` starts at `base + i * size`. The memory must stay
        valid until `unregister_buffer_group`.

        Args:
            base: Address of buffer 0.
            size: Bytes per buffer.
            count: Number of buffers, in 1..65536.
            group_id: Caller-chosen id, unique per driver.
        """
        ...

    def unregister_buffer_group(mut self, group_id: UInt16) raises:
        """Tear down a buffer group; no operation may still select from it.

        Args:
            group_id: The group to remove.
        """
        ...

    def return_buffer(mut self, group_id: UInt16, buf_id: UInt16):
        """Make a delivered buffer available to the group again.

        Never raises: returning to an unregistered group is a no-op.

        Args:
            group_id: The group the buffer belongs to.
            buf_id: The id read from the delivery's flags.
        """
        ...

    def backend(self) -> Backend:
        """Return which kernel I/O mechanism this driver uses."""
        ...

    def supports(self, feature: DriverFeature) -> Bool:
        """Return whether `feature` can be used on this driver.

        A driver that emulates the feature in userspace answers True.
        The answer is fixed at construction; nothing is submitted.

        Args:
            feature: The capability to query.

        Returns:
            True if submissions relying on `feature` will be accepted.
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

    def backend(self) -> Backend:
        """Return which kernel I/O mechanism this driver uses."""
        ...
