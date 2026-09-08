from boucle.socle.linux.io_uring.types import (
    Sqe,
    SQE,
    SQE128,
    addr3_struct,
    IoUringOp,
    IoUringSqeFlags,
    IoUringFsyncFlags,
    IoUringTimeoutFlags,
    IoUringFileDescriptor,
    IoUringFd,
)
from boucle.socle.linux.fd import UnsafeFd, NoFd
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.ptr import null_ptr
from std.memory import Pointer


@always_inline
def _prep_rw[
    Fd: IoUringFileDescriptor
](mut sqe: Sqe, op: IoUringOp, fd: Fd, addr: UInt64, len: UInt32):
    sqe.opcode = op
    sqe.flags = Fd.SQE_FLAGS
    sqe.ioprio = 0
    sqe.fd = fd.unsafe_fd()
    sqe.off_or_addr2_or_cmd_op = 0
    sqe.addr_or_splice_off_in_or_msgring_cmd = addr
    sqe.len_or_poll_flags = len
    sqe.op_flags = 0
    sqe.user_data = 0
    sqe.buf_index_or_buf_group = 0
    sqe.personality = 0
    sqe.splice_fd_in_or_file_index_or_optlen_or_addr_len = 0
    sqe.addr3_or_optval_or_cmd = addr3_struct()

    comptime if sqe.type is SQE128:
        sqe._big_sqe = sqe.Array(0)


@always_inline
def _prep_addr[
    Fd: IoUringFileDescriptor
](mut sqe: Sqe, op: IoUringOp, fd: Fd, addr: UInt64, addr_len: UInt64):
    sqe.opcode = op
    sqe.flags = Fd.SQE_FLAGS
    sqe.ioprio = 0
    sqe.fd = fd.unsafe_fd()
    sqe.off_or_addr2_or_cmd_op = addr_len
    sqe.addr_or_splice_off_in_or_msgring_cmd = addr
    sqe.len_or_poll_flags = 0
    sqe.op_flags = 0
    sqe.user_data = 0
    sqe.buf_index_or_buf_group = 0
    sqe.personality = 0
    sqe.splice_fd_in_or_file_index_or_optlen_or_addr_len = 0
    sqe.addr3_or_optval_or_cmd = addr3_struct()

    comptime if sqe.type is SQE128:
        sqe._big_sqe = sqe.Array(0)


trait SqeAttrs:
    def user_data(var self, value: UInt64) -> Self:
        ...

    def personality(var self, value: UInt16) -> Self:
        ...

    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        ...


trait Operation(SqeAttrs, Movable):
    ...


struct Nop[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Do not perform any I/O.
    A no-op is more useful than may appear at first glance.
    For example, you could set `IOSQE_IO_DRAIN_BIT` using `sqe_flags()`,
    to use the no-op to know when the ring is idle before acting
    on a kill signal. Also this is useful for testing the performance
    of the `io_uring` implementation itself.
    """

    comptime SINCE = 5.1

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__(out self, ref [Self.origin]sqe: Sqe[Self.type]):
        _prep_rw(
            sqe,
            IoUringOp.NOP,
            IoUringFd[False](unsafe_fd=NoFd),
            0,
            0,
        )
        self.sqe = Pointer(to=sqe)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^


struct Read[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Read, equivalent to `pread(2)`."""

    comptime SINCE = 5.6

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__[
        Fd: IoUringFileDescriptor,
    ](
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: Fd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt,
    ):
        _prep_rw(
            sqe,
            IoUringOp.READ,
            fd,
            UInt64(Int(unsafe_ptr)),
            UInt32(len),
        )
        self.sqe = Pointer(to=sqe)

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: UnsafeFd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt,
    ):
        self = Self(sqe, IoUringFd[False](unsafe_fd=fd), unsafe_ptr, len)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^

    @always_inline("nodebug")
    def ioprio(var self, value: UInt16) -> Self:
        self.sqe[].ioprio = value
        return self^

    @always_inline("nodebug")
    def offset(var self, value: UInt64) -> Self:
        self.sqe[].off_or_addr2_or_cmd_op = value
        return self^

    @always_inline("nodebug")
    def rw_flags(var self, flags: UInt32) -> Self:
        self.sqe[].op_flags = flags
        return self^

    @always_inline("nodebug")
    def buf_group(var self, value: UInt16) -> Self:
        self.sqe[].buf_index_or_buf_group = value
        return self^


struct Write[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Write, equivalent to `pwrite(2)`."""

    comptime SINCE = 5.6

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__[
        Fd: IoUringFileDescriptor,
    ](
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: Fd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt,
    ):
        _prep_rw(
            sqe,
            IoUringOp.WRITE,
            fd,
            UInt64(Int(unsafe_ptr)),
            UInt32(len),
        )
        self.sqe = Pointer(to=sqe)

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: UnsafeFd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt,
    ):
        self = Self(sqe, IoUringFd[False](unsafe_fd=fd), unsafe_ptr, len)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^

    @always_inline("nodebug")
    def offset(var self, value: UInt64) -> Self:
        self.sqe[].off_or_addr2_or_cmd_op = value
        return self^

    @always_inline("nodebug")
    def rw_flags(var self, flags: UInt32) -> Self:
        self.sqe[].op_flags = flags
        return self^


struct Recv[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Receive a message from a socket, equivalent to `recv(2)`."""

    comptime SINCE = 5.6

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__[
        Fd: IoUringFileDescriptor,
    ](
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: Fd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt,
    ):
        _prep_rw(
            sqe,
            IoUringOp.RECV,
            fd,
            UInt64(Int(unsafe_ptr)),
            UInt32(len),
        )
        self.sqe = Pointer(to=sqe)

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: UnsafeFd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt,
    ):
        self = Self(sqe, IoUringFd[False](unsafe_fd=fd), unsafe_ptr, len)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^

    @always_inline("nodebug")
    def recv_flags(var self, flags: UInt32) -> Self:
        self.sqe[].op_flags = flags
        return self^

    @always_inline("nodebug")
    def ioprio(var self, value: UInt16) -> Self:
        self.sqe[].ioprio = value
        return self^

    @always_inline("nodebug")
    def buf_group(var self, value: UInt16) -> Self:
        self.sqe[].buf_index_or_buf_group = value
        return self^


struct RecvMsg[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Receive a message from a socket, equivalent to `recvmsg(2)`."""

    comptime SINCE = 5.3

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__[
        Fd: IoUringFileDescriptor,
    ](
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: Fd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt = 1,
    ):
        _prep_rw(
            sqe,
            IoUringOp.RECVMSG,
            fd,
            UInt64(Int(unsafe_ptr)),
            UInt32(len),
        )
        self.sqe = Pointer(to=sqe)

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: UnsafeFd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt = 1,
    ):
        self = Self(sqe, IoUringFd[False](unsafe_fd=fd), unsafe_ptr, len)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^

    @always_inline("nodebug")
    def recv_flags(var self, flags: UInt32) -> Self:
        self.sqe[].op_flags = flags
        return self^

    @always_inline("nodebug")
    def ioprio(var self, value: UInt16) -> Self:
        self.sqe[].ioprio = value
        return self^

    @always_inline("nodebug")
    def buf_group(var self, value: UInt16) -> Self:
        self.sqe[].buf_index_or_buf_group = value
        return self^


struct SendMsg[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Send a message on a socket, equivalent to `sendmsg(2)`."""

    comptime SINCE = 5.3

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__[
        Fd: IoUringFileDescriptor,
    ](
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: Fd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt = 1,
    ):
        _prep_rw(
            sqe,
            IoUringOp.SENDMSG,
            fd,
            UInt64(Int(unsafe_ptr)),
            UInt32(len),
        )
        self.sqe = Pointer(to=sqe)

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: UnsafeFd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt = 1,
    ):
        self = Self(sqe, IoUringFd[False](unsafe_fd=fd), unsafe_ptr, len)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^

    @always_inline("nodebug")
    def send_flags(var self, flags: UInt32) -> Self:
        self.sqe[].op_flags = flags
        return self^


struct Send[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Send a message on a socket, equivalent to `send(2)`."""

    comptime SINCE = 5.6

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__[
        Fd: IoUringFileDescriptor,
    ](
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: Fd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt,
    ):
        _prep_rw(
            sqe,
            IoUringOp.SEND,
            fd,
            UInt64(Int(unsafe_ptr)),
            UInt32(len),
        )
        self.sqe = Pointer(to=sqe)

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: UnsafeFd,
        unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        len: UInt,
    ):
        self = Self(sqe, IoUringFd[False](unsafe_fd=fd), unsafe_ptr, len)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^

    @always_inline("nodebug")
    def send_flags(var self, flags: UInt32) -> Self:
        self.sqe[].op_flags = flags
        return self^


struct Accept[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Accept a new connection on a socket, equivalent to `accept4(2)`."""

    comptime SINCE = 5.5

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__[
        Fd: IoUringFileDescriptor,
    ](out self, ref [Self.origin]sqe: Sqe[Self.type], fd: Fd):
        self = Self(
            sqe,
            fd,
            null_ptr[c_void, ImmStaticOrigin](),
            null_ptr[c_void, ImmStaticOrigin](),
        )

    @always_inline
    def __init__(out self, ref [Self.origin]sqe: Sqe[Self.type], fd: UnsafeFd):
        self = Self(sqe, IoUringFd[False](unsafe_fd=fd))

    @always_inline
    def __init__[
        Fd: IoUringFileDescriptor,
    ](
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: Fd,
        addr_unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        addr_len_unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
    ):
        _prep_addr(
            sqe,
            IoUringOp.ACCEPT,
            fd,
            UInt64(Int(addr_unsafe_ptr)),
            UInt64(Int(addr_len_unsafe_ptr)),
        )
        self.sqe = Pointer(to=sqe)

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: UnsafeFd,
        addr_unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        addr_len_unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
    ):
        self = Self(
            sqe,
            IoUringFd[False](unsafe_fd=fd),
            addr_unsafe_ptr,
            addr_len_unsafe_ptr,
        )

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^

    @always_inline("nodebug")
    def socket_flags(var self, flags: UInt32) -> Self:
        self.sqe[].op_flags = flags
        return self^

    @always_inline("nodebug")
    def ioprio(var self, value: UInt16) -> Self:
        self.sqe[].ioprio = value
        return self^


struct Connect[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Connect a socket, equivalent to `connect(2)`."""

    comptime SINCE = 5.5

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__[
        Fd: IoUringFileDescriptor,
    ](
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: Fd,
        addr_unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        addr_len: UInt64,
    ):
        _prep_addr(
            sqe,
            IoUringOp.CONNECT,
            fd,
            UInt64(Int(addr_unsafe_ptr)),
            addr_len,
        )
        self.sqe = Pointer(to=sqe)

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: UnsafeFd,
        addr_unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        addr_len: UInt64,
    ):
        self = Self(
            sqe, IoUringFd[False](unsafe_fd=fd), addr_unsafe_ptr, addr_len
        )

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^


struct Timeout[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Schedule a timeout, equivalent to a kernel timer.

    The `addr` field points to a `kernel_timespec` (16 bytes: tv_sec i64 + tv_nsec i64).
    The `off` field is the completion event count (0 = pure timer).
    CQE result: -ETIME on normal expiry, 0 if canceled.
    """

    comptime SINCE = 5.4

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        ts_ptr: Pointer[c_void, MutUntrackedOrigin],
        count: UInt64 = 0,
    ):
        _prep_rw(
            sqe,
            IoUringOp.TIMEOUT,
            IoUringFd[False](unsafe_fd=NoFd),
            UInt64(Int(ts_ptr)),
            UInt32(1),  # len = 1 (number of timespec entries)
        )
        sqe.off_or_addr2_or_cmd_op = count
        self.sqe = Pointer(to=sqe)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^


struct AsyncCancel[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Cancel a previously submitted op matched by `user_data`.

    The cancel itself produces a CQE: `result == 0` if the target was
    cancelled in flight, `-ENOENT` if it had already completed. When the
    target is cancelled, it also produces a CQE with `result == -ECANCELED`.

    `cancel_flags` accepts the kernel's `IORING_ASYNC_CANCEL_*` bits
    (e.g. `IORING_ASYNC_CANCEL_ALL` to cancel every match, or
    `IORING_ASYNC_CANCEL_FD` to match by fd instead of user_data — when
    matching by fd, the fd lives in `sqe.fd`, set via a different builder).
    The default (0) matches a single op by `target_user_data`.
    """

    comptime SINCE = 5.5

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        target_user_data: UInt64,
    ):
        _prep_rw(
            sqe,
            IoUringOp.ASYNC_CANCEL,
            IoUringFd[False](unsafe_fd=NoFd),
            target_user_data,
            0,
        )
        self.sqe = Pointer(to=sqe)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^

    @always_inline("nodebug")
    def cancel_flags(var self, flags: UInt32) -> Self:
        """Set `IORING_ASYNC_CANCEL_*` bits (aliased to op_flags slot)."""
        self.sqe[].op_flags = flags
        return self^


struct TimeoutUpdate[type: SQE, origin: MutOrigin](
    RegisterPassable, Operation
):
    """Re-arm a pending timeout matched by `user_data` (TIMEOUT_REMOVE with IORING_TIMEOUT_UPDATE).

    Layout is liburing's `io_uring_prep_timeout_update`: `addr` carries
    the target's user_data, `off` the new `kernel_timespec` pointer,
    `len` 0. Relative to the moment the SQE is issued unless
    `IoUringTimeoutFlags.ABS` is added through `timeout_flags`. The
    kernel copies the timespec while it consumes the SQE, so it need
    not outlive the submit.
    """

    comptime SINCE = 5.11

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        target_user_data: UInt64,
        ts_ptr: Pointer[c_void, MutUntrackedOrigin],
    ):
        _prep_rw(
            sqe,
            IoUringOp.TIMEOUT_REMOVE,
            IoUringFd[False](unsafe_fd=NoFd),
            target_user_data,
            0,
        )
        sqe.off_or_addr2_or_cmd_op = UInt64(Int(ts_ptr))
        sqe.op_flags = UInt32(IoUringTimeoutFlags.UPDATE.value)
        self.sqe = Pointer(to=sqe)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^

    @always_inline("nodebug")
    def timeout_flags(var self, flags: IoUringTimeoutFlags) -> Self:
        """Add `IORING_TIMEOUT_*` bits; the UPDATE bit is always kept."""
        self.sqe[].op_flags = UInt32(
            (flags | IoUringTimeoutFlags.UPDATE).value
        )
        return self^


struct ProvideBuffers[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Provide buffers to io_uring for kernel-side buffer selection.

    Used with multishot recvmsg: the kernel picks a buffer from the
    provided pool for each received message.  Requires kernel >= 5.19.
    """

    comptime SINCE = 5.19

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        buf_base: Pointer[c_void, ImmStaticOrigin],
        buf_size: UInt32,
        count: UInt32,
        group_id: UInt16,
        base_buf_id: UInt16,
    ):
        sqe.opcode = IoUringOp.PROVIDE_BUFFERS
        sqe.flags = IoUringSqeFlags()
        sqe.ioprio = 0
        sqe.fd = Int32(count)
        sqe.off_or_addr2_or_cmd_op = UInt64(base_buf_id)
        sqe.addr_or_splice_off_in_or_msgring_cmd = UInt64(Int(buf_base))
        sqe.len_or_poll_flags = buf_size
        sqe.op_flags = 0
        sqe.user_data = 0
        sqe.buf_index_or_buf_group = group_id
        sqe.personality = 0
        sqe.splice_fd_in_or_file_index_or_optlen_or_addr_len = 0
        sqe.addr3_or_optval_or_cmd = addr3_struct()
        self.sqe = Pointer(to=sqe)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^


struct Fsync[type: SQE, origin: MutOrigin](RegisterPassable, Operation):
    """Fsync, equivalent to `fsync(2)` or `fdatasync(2)`."""

    comptime SINCE = 5.1

    var sqe: Pointer[Sqe[Self.type], Self.origin]

    @always_inline
    def __init__(
        out self,
        ref [Self.origin]sqe: Sqe[Self.type],
        fd: UnsafeFd,
    ):
        _prep_rw(
            sqe,
            IoUringOp.FSYNC,
            IoUringFd[False](unsafe_fd=fd),
            UInt64(0),
            UInt32(0),
        )
        self.sqe = Pointer(to=sqe)

    @always_inline("nodebug")
    def user_data(var self, value: UInt64) -> Self:
        self.sqe[].user_data = value
        return self^

    @always_inline("nodebug")
    def personality(var self, value: UInt16) -> Self:
        self.sqe[].personality = value
        return self^

    @always_inline("nodebug")
    def fsync_flags(var self, flags: IoUringFsyncFlags) -> Self:
        """DATASYNC for fdatasync semantics."""
        self.sqe[].op_flags = UInt32(flags.value)
        return self^

    @always_inline("nodebug")
    def sqe_flags(var self, flags: IoUringSqeFlags) -> Self:
        self.sqe[].flags |= flags
        return self^
