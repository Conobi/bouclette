"""Linux io_uring backend for the proactor IoDriver trait.

Wraps boucle's IoUring type and implements tick() (completion dispatch via
Completion pointer recovery) and operation methods (nop, connect,
timeout, cancel, accept, recv, send, recvmsg, sendmsg).
"""

from std.memory import Pointer

from std.memory.alloc import unsafe_alloc as _heap_alloc

from boucle.socle.linux.io_uring import IoUring
from boucle.socle.linux.io_uring.op import Nop, Connect, Accept, Recv, Send, RecvMsg, SendMsg, Timeout, AsyncCancel, ProvideBuffers, Fsync
from boucle.socle.linux.io_uring.op import Read as ReadOp
from boucle.socle.linux.io_uring.op import Write as WriteOp
from boucle.socle.linux.io_uring.types import (
    IoUringSqeFlags,
    IoUringAcceptFlags,
    IoUringBufReg,
    IoUringEnterFlags,
    IoUringFeatureFlags,
    IoUringFsyncFlags,
    IoUringGetEventsArg,
    IoUringOp,
    IoUringParams,
    IoUringProbe,
    IoUringRegisterOp,
    IoUringSetupFlags,
    EnterArg,
)
from boucle.socle.linux.raw import (
    IORING_RECV_MULTISHOT,
    MSG_TRUNC,
    EAGAIN,
    EEXIST,
    EINVAL,
    ENOENT,
    ETIME,
    EOPNOTSUPP,
    __kernel_timespec,
)
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.linux.raw import msghdr
from boucle.socle.linux.errno import Errno
from boucle.socle.linux.uname import kernel_version, KernelVersion
from boucle.socle.linux.mm import get_page_size
from boucle.handle import RawHandle
from boucle.error import IOError
from boucle.socle.ptr import null_ptr
from boucle.drivers.bufring import BufRing, _next_pow2, _IO_URING_BUF_SIZE
from boucle.proactor.completion import Completion
from boucle.drivers.backend import Backend
from boucle.drivers.driver import IoDriver
from boucle.drivers.feature import DriverFeature


# Largest provided-buffer ring the kernel registers (IO_RING_MAX_ENTRIES).
comptime _MAX_RING_ENTRIES = 32768

# Kernel versions that introduced the features the opcode probe cannot see.
comptime _MULTISHOT_RECVMSG_MAJOR = 6
comptime _MULTISHOT_RECVMSG_MINOR = 0
comptime _BUFFER_RING_MAJOR = 5
comptime _BUFFER_RING_MINOR = 19

# user_data of the sentinel timeout a bounded tick submits on kernels
# without IORING_FEAT_EXT_ARG. Real operations carry a Completion
# address, never all ones; liburing reserves the same value
# (LIBURING_UDATA_TIMEOUT). Completions carrying it are skipped and not
# counted.
comptime _SENTINEL_USER_DATA = UInt64.MAX

comptime _NS_PER_MS = Int64(1_000_000)


def _is_etime(e: Error) -> Bool:
    """Return True when `e` is the socle layer's rendering of -ETIME.

    Args:
        e: An error raised by a socle syscall wrapper.

    Returns:
        True for `"-62"`; False for any other text.
    """
    try:
        return Errno(error=e) is Errno(errno=UInt16(ETIME))
    except:
        return False


def _unsupported() -> Error:
    """Build the socle-style error for a feature this kernel lacks.

    The text is the negated errno, the same contract every socle
    syscall wrapper follows, so `IOError.from_error` recovers
    EOPNOTSUPP from it.

    Returns:
        An Error whose message is `"-95"`.
    """
    return Error(String(-EOPNOTSUPP))


def _queue_full() -> Error:
    """Build the socle-style error for a submission queue still full after a flush.

    Every submitting method enters the ring without waiting when the
    queue is full and retries once; a queue still full after that means
    the kernel did not consume the entries. That is a transient condition
    the caller may retry at its next flush, so it is reported as EAGAIN
    in the same negated-errno text every socle wrapper uses and
    `IOError.from_error` recovers, never as a plain message.

    Returns:
        An Error whose message is `"-11"`.
    """
    return Error(String(-EAGAIN))


def _timespec_from_ms(timeout_ms: Int) -> __kernel_timespec:
    """Split a non-negative millisecond count into a kernel timespec.

    Args:
        timeout_ms: Milliseconds, >= 0.

    Returns:
        `tv_sec = timeout_ms // 1000`, `tv_nsec = (timeout_ms % 1000) * 1e6`.
    """
    return __kernel_timespec(
        tv_sec=Int64(timeout_ms // 1000),
        tv_nsec=Int64(timeout_ms % 1000) * _NS_PER_MS,
    )


@fieldwise_init
struct _KernelFeatures(TrivialRegisterPassable):
    """The three feature answers `supports()` reports from.

    Fields:
        multishot_recvmsg: RECVMSG probed as supported and the kernel is
                            6.0 or newer.
        buffer_ring: The kernel is 5.19 or newer.
        timeout_arg: `IORING_FEAT_EXT_ARG` was reported at setup.
    """

    var multishot_recvmsg: Bool
    var buffer_ring: Bool
    var timeout_arg: Bool


def _features_from(
    kv: KernelVersion, probe_ok: Bool, features: IoUringFeatureFlags
) -> _KernelFeatures:
    """Compute the version/probe-gated feature answers.

    Pure function factored out of `IoUringDriver.__init__` so the
    degrade-on-failure path is unit-testable without forcing a real
    `uname(2)` failure: an unreadable kernel release becomes
    `KernelVersion(0, 0)`, which fails every `at_least` gate below, so
    both version-gated features answer False.

    Args:
        kv: The kernel version to gate against. `KernelVersion(0, 0)`
            simulates an unreadable release.
        probe_ok: Whether `IORING_REGISTER_PROBE` reported RECVMSG as
                  supported.
        features: The setup feature flags reported by `io_uring_setup`.

    Returns:
        The three feature answers `supports()` reports from.
    """
    return _KernelFeatures(
        multishot_recvmsg=probe_ok
        and kv.at_least(_MULTISHOT_RECVMSG_MAJOR, _MULTISHOT_RECVMSG_MINOR),
        buffer_ring=kv.at_least(_BUFFER_RING_MAJOR, _BUFFER_RING_MINOR),
        timeout_arg=Bool(features & IoUringFeatureFlags.EXT_ARG),
    )


struct IoUringDriver(IoDriver):
    """IoDriver backed by Linux io_uring.

    Each submitted operation stores its Completion pointer as the
    operation user_data. On completion arrival, tick() recovers the
    pointer and fires the callback with the kernel result and flags.

    Construction reads three facts about the running kernel and keeps
    only the answers `supports()` needs: the opcode probe
    (`IORING_REGISTER_PROBE`), the release from `uname` for multishot
    recvmsg (6.0) and buffer rings (5.19), which the probe does not
    expose, and the setup feature flags for `IORING_FEAT_EXT_ARG`. The
    ring is always requested with `IORING_SETUP_NO_SQARRAY`.

    Registered buffer rings are kept in `_groups`, keyed by group id, so
    `return_buffer` can recycle a buffer without the caller holding the
    `BufRing`. The table is heap-boxed because a completion callback may
    call `return_buffer` while `tick()` holds `mut self`; going through a
    loaded pointer guarantees the callback's writes are observed.

    Fields:
        _ring: The io_uring instance.
        _groups: Registered buffer rings keyed by group id (see above).
        _setup_flags: The io_uring setup flags requested at construction
                      (always includes `IORING_SETUP_NO_SQARRAY`).
        _supports_multishot_recvmsg: RECVMSG probes as supported and the
                                     kernel is 6.0 or newer.
        _supports_buffer_ring: The kernel is 5.19 or newer.
        _supports_timeout_arg: `IORING_FEAT_EXT_ARG` was reported at setup.
        _sentinel_ts: Timespec of the sentinel timeout on kernels without
                      `IORING_FEAT_EXT_ARG`; the kernel copies it at
                      submission, so one field serves every bounded tick.
    """

    var _ring: IoUring[]
    var _groups: Pointer[List[BufRing], MutUntrackedOrigin]
    var _setup_flags: IoUringSetupFlags
    var _supports_multishot_recvmsg: Bool
    var _supports_buffer_ring: Bool
    var _supports_timeout_arg: Bool
    var _sentinel_ts: __kernel_timespec

    def __init__(out self, *, capacity: Int = 64) raises:
        """Construct an IoUringDriver with the given capacity hint.

        Sets up the ring with `IORING_SETUP_NO_SQARRAY`, then reads
        three facts about the running kernel and keeps only the
        answers `supports()` needs: registers the opcode probe
        (`IORING_REGISTER_PROBE`) -- one extra `io_uring_register`
        syscall beyond ring setup -- to learn whether RECVMSG is
        supported; reads the release via `uname(2)` for the two
        features the probe cannot see (multishot recvmsg at 6.0,
        buffer rings at 5.19); and reads the setup feature flags the
        kernel reported for `IORING_FEAT_EXT_ARG`.

        Neither optional read aborts construction on failure. A failed
        probe register (e.g. a pre-5.6 kernel without
        `IORING_REGISTER_PROBE`) degrades to "RECVMSG unsupported". An
        unreadable kernel release degrades to `KernelVersion(0, 0)`,
        which fails every version gate and so answers False to both
        multishot recvmsg and buffer rings.

        Args:
            capacity: How many operations the driver should be ready to
                      hold at once (default 64). Becomes the io_uring
                      submission queue size, which the kernel rounds up
                      to a power of two.
        """
        self._sentinel_ts = __kernel_timespec(tv_sec=Int64(0), tv_nsec=Int64(0))
        var params = IoUringParams()
        params.flags |= IoUringSetupFlags.NO_SQARRAY
        self._ring = IoUring[](sq_entries=UInt32(capacity), params=params)
        self._setup_flags = params.flags
        var groups = _heap_alloc[List[BufRing]](1)
        groups.unsafe_write(List[BufRing]())
        self._groups = Pointer[List[BufRing], MutUntrackedOrigin](
            unsafe_from_address=Int(groups)
        )

        var probe_ok: Bool
        var probe = IoUringProbe()
        try:
            _ = self._ring.register(
                probe.as_register_arg(
                    unsafe_opcode=IoUringRegisterOp.REGISTER_PROBE
                )
            )
            probe_ok = probe.is_supported(IoUringOp.RECVMSG)
        except:
            # Catches any register() failure, not only a pre-5.6 kernel
            # missing REGISTER_PROBE (EINVAL): whatever the cause, none
            # of the optional features this probe would confirm are
            # assumed usable.
            probe_ok = False

        var kv: KernelVersion
        try:
            kv = kernel_version()
        except:
            # An unreadable release degrades to "no optional feature":
            # KernelVersion(0, 0) fails every at_least gate.
            kv = KernelVersion(0, 0)

        var features = _features_from(kv, probe_ok, params.features)
        self._supports_multishot_recvmsg = features.multishot_recvmsg
        self._supports_buffer_ring = features.buffer_ring
        self._supports_timeout_arg = features.timeout_arg

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._ring = move._ring^
        self._groups = move._groups
        self._setup_flags = move._setup_flags
        self._supports_multishot_recvmsg = move._supports_multishot_recvmsg
        self._supports_buffer_ring = move._supports_buffer_ring
        self._supports_timeout_arg = move._supports_timeout_arg
        self._sentinel_ts = move._sentinel_ts

    def __deinit__(deinit self):
        """Unregister every buffer ring still in the table, then free it.

        The ring is destroyed after this body returns, so the
        unregister calls still have a live ring to talk to; failures are
        ignored because closing the ring frees kernel-side rings anyway.
        """
        for i in range(len(self._groups[])):
            try:
                self.unregister_buf_ring(self._groups[][i].bgid)
            except:
                pass
        self._groups.unsafe_deinit_pointee()
        self._groups.unsafe_free()

    def tick(mut self, wait: Bool, timeout_ms: Int = -1) raises -> Int:
        """Submit pending operations, wait at most `timeout_ms`, dispatch.

        Recovers the Completion pointer from each completion's user_data
        field and invokes the callback. Skips completions with
        user_data == 0 (internal kernel notifications) and the sentinel
        timeout's user_data, neither of which is counted.

        A bounded wait uses the enter call's extended argument when the
        kernel reported `IORING_FEAT_EXT_ARG`; the kernel then answers
        -ETIME when the bound expires first, which is swallowed here.
        Without the feature a one-shot timeout with `_SENTINEL_USER_DATA`
        is submitted alongside the pending work and the wait is for one
        completion, which the sentinel satisfies if nothing else does.
        On kernels without `IORING_FEAT_EXT_ARG`, a bounded tick that
        returns early for a reason other than its own sentinel firing
        leaves that sentinel armed, so a later unbounded tick may wake
        with zero dispatched once it fires; callers loop on their own
        pending count rather than on one tick's return value.

        Args:
            wait: If True, block until at least one completion arrives
                  or the bound expires. If False, dispatch only
                  already-available completions; `timeout_ms` is ignored.
            timeout_ms: Upper bound on the wait in milliseconds. -1 means
                        no bound; 0 means poll.

        Returns:
            The number of completed operations, excluding skipped ones.
        """
        if wait and timeout_ms >= 0:
            self._submit_and_wait_bounded(timeout_ms)
        else:
            var wait_nr = UInt32(1) if wait else UInt32(0)
            _ = self._ring.submit_and_wait(wait_nr=wait_nr)
        var dispatched = 0
        var cq = self._ring.cq(wait_nr=0)
        while cq:
            var cqe = cq.__next__()
            if cqe.user_data == 0 or cqe.user_data == _SENTINEL_USER_DATA:
                continue
            var cmp = Pointer[Completion, MutUntrackedOrigin](
                unsafe_from_address=Int(cqe.user_data)
            )
            cmp[].fire(Int(cqe.res), UInt32(cqe.flags.value))
            dispatched += 1
        cq^.__deinit__()
        return dispatched

    def _submit_and_wait_bounded(mut self, timeout_ms: Int) raises:
        """Submit pending work and wait for one completion or `timeout_ms`.

        Args:
            timeout_ms: The bound in milliseconds, >= 0.
        """
        var ts = _timespec_from_ms(timeout_ms)
        if self._supports_timeout_arg:
            var arg = IoUringGetEventsArg()
            arg.ts = UInt64(Int(Pointer(to=ts)))
            var arg_p = Pointer(to=arg)
            var enter_arg = EnterArg[
                24, IoUringEnterFlags.EXT_ARG, ImmStaticOrigin
            ](
                arg_unsafe_ptr=Pointer[c_void, ImmStaticOrigin](
                    unsafe_from_address=Int(arg_p)
                )
            )
            try:
                _ = self._ring.submit_and_wait(wait_nr=UInt32(1), arg=enter_arg)
            except e:
                if not _is_etime(e):
                    raise e
            _ = ts
            _ = arg
            return

        # Fallback: a sentinel timeout operation stands in for the bound.
        self._sentinel_ts = ts
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var ts_cv = Pointer[c_void, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._sentinel_ts))
        )
        _ = Timeout(sq.__next__(), ts_cv).user_data(_SENTINEL_USER_DATA)
        _ = self._ring.submit_and_wait(wait_nr=UInt32(1))

    def nop(
        mut self, c: Pointer[Completion, MutUntrackedOrigin]
    ) raises:
        """Queue a no-op operation with the given Completion token.

        Args:
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        _ = Nop(sq.__next__()).user_data(UInt64(Int(c)))

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
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var addr_cv = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(addr)
        )
        _ = Connect(sq.__next__(), fd, addr_cv, addr_len).user_data(
            UInt64(Int(c))
        )

    def timeout(
        mut self,
        ts: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a timeout (kernel timer).

        Args:
            ts: Opaque pointer to a 16-byte kernel_timespec. Caller
                must keep it alive until the completion fires.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var ts_cv = Pointer[c_void, MutUntrackedOrigin](
            unsafe_from_address=Int(ts)
        )
        _ = Timeout(sq.__next__(), ts_cv).user_data(UInt64(Int(c)))

    def cancel(
        mut self,
        target: Pointer[Completion, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Matches the target by its Completion pointer (the user_data
        stored in the original operation).

        Args:
            target: Pointer to the Completion of the op to cancel.
            c: Pointer to the Completion token for the cancel itself.
        """
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        _ = AsyncCancel(sq.__next__(), UInt64(Int(target))).user_data(
            UInt64(Int(c))
        )

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
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        _ = Accept(sq.__next__(), fd).user_data(UInt64(Int(c)))

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
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var buf_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(buf)
        )
        _ = Recv(sq.__next__(), fd, buf_ptr, UInt(len)).user_data(
            UInt64(Int(c))
        )

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
            buf: Data to send. Must remain valid until completion fires.
            len: Number of bytes to send.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var buf_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(buf)
        )
        _ = Send(sq.__next__(), fd, buf_ptr, UInt(len)).user_data(
            UInt64(Int(c))
        )

    def recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
        flags: UInt32 = 0,
    ) raises:
        """Queue a recvmsg on socket `fd`.

        `flags` go to the kernel as the SQE's receive flags. A caller
        that passes MSG_TRUNC on a datagram socket gets the full
        datagram length as the completion result even when the iov was
        too small (the copied bytes are still capped at the iov, and
        `msg_flags` carries MSG_TRUNC); on a stream socket MSG_TRUNC
        discards instead, so the caller must not ask for it there. The
        epoll driver receives the same way, so a caller reads one
        contract on both backends.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to msghdr (and all referenced buffers).
                 Must remain valid until completion fires.
            c: Pointer to the caller-owned Completion token.
            flags: `recvmsg(2)` flags to pass through; 0 for none.
        """
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var msg_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(msg)
        )
        _ = RecvMsg(sq.__next__(), fd, msg_ptr)
            .recv_flags(flags)
            .user_data(UInt64(Int(c)))

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
            msg: Opaque pointer to msghdr with destination and payload.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var msg_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(msg)
        )
        _ = SendMsg(sq.__next__(), fd, msg_ptr).user_data(UInt64(Int(c)))

    def read(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        offset: UInt64,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a pread via IORING_OP_READ.

        Args:
            fd: File descriptor opened for reading.
            buf: Destination buffer.
            len: Maximum bytes to read.
            offset: File offset in bytes.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var buf_cv = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(buf)
        )
        _ = ReadOp(sq.__next__(), fd, buf_cv, UInt(len)).offset(
            offset
        ).user_data(UInt64(Int(c)))

    def write(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        offset: UInt64,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a pwrite via IORING_OP_WRITE.

        Args:
            fd: File descriptor opened for writing.
            buf: Source buffer.
            len: Number of bytes to write.
            offset: File offset in bytes.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var buf_cv = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(buf)
        )
        _ = WriteOp(sq.__next__(), fd, buf_cv, UInt(len)).offset(
            offset
        ).user_data(UInt64(Int(c)))

    def fsync(
        mut self,
        fd: RawHandle,
        datasync: Bool,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an fsync via IORING_OP_FSYNC.

        Args:
            fd: File descriptor.
            datasync: If True, fdatasync semantics.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        if datasync:
            _ = Fsync(sq.__next__(), fd).user_data(
                UInt64(Int(c))
            ).fsync_flags(IoUringFsyncFlags.DATASYNC)
        else:
            _ = Fsync(sq.__next__(), fd).user_data(UInt64(Int(c)))

    def provide_buffers(
        mut self,
        buf_base: Pointer[UInt8, MutUntrackedOrigin],
        buf_size: Int,
        count: Int,
        group_id: UInt16,
        base_buf_id: UInt16,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Register count contiguous buffers with io_uring.

        Buffers are contiguous: buf_base[i * buf_size .. (i+1) * buf_size].
        Each buffer gets ID base_buf_id + i.

        Args:
            buf_base: Base pointer for the contiguous buffer array.
            buf_size: Size of each individual buffer in bytes.
            count: Number of buffers to register.
            group_id: Buffer group ID to register under.
            base_buf_id: Starting buffer ID.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var buf_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(buf_base)
        )
        _ = ProvideBuffers(
            sq.__next__(),
            buf_ptr,
            UInt32(buf_size),
            UInt32(count),
            group_id,
            base_buf_id,
        ).user_data(UInt64(Int(c)))

    def recv_multishot(
        mut self,
        fd: RawHandle,
        buf_group: UInt16,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a multishot recv with provided buffer selection (TCP).

        The kernel selects a buffer from `buf_group` per arrival and
        produces one completion per chunk. The payload begins at offset 0 of
        the chosen buffer (no io_uring_recvmsg_out header). The buffer
        ID is in completion flags bits 16-31 when IORING_CQE_F_BUFFER is set.
        Re-arm when completion flags lack IORING_CQE_F_MORE.

        Args:
            fd: The socket file descriptor.
            buf_group: The provided buffer group ID to select from.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var null_buf = null_ptr[c_void, ImmStaticOrigin]()
        _ = Recv(sq.__next__(), fd, null_buf, UInt(0))
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(UInt64(Int(c)))

    def accept_multishot(
        mut self,
        fd: RawHandle,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a multishot accept on listening socket `fd`.

        Produces one completion per accepted connection. The completion result is the
        accepted file descriptor (>= 0) on success. Re-arm when completion
        flags lack IORING_CQE_F_MORE. Requires kernel >= 5.19.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise _queue_full()
        var sq = self._ring.unsynced_sq()
        _ = Accept(sq.__next__(), fd)
            .ioprio(IoUringAcceptFlags.MULTISHOT.value)
            .user_data(UInt64(Int(c)))

    def multishot_recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[msghdr, MutUntrackedOrigin],
        buf_group: UInt16,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a multishot recvmsg with provided buffer selection.

        Produces one completion per received message. The buffer ID is in
        completion flags bits 16-31 when IORING_CQE_F_BUFFER is set. The
        same Completion fires multiple times until the multishot ends
        (completion without IORING_CQE_F_MORE flag). Caller must re-arm if
        desired.

        The receive asks for MSG_TRUNC, so the delivery header's
        `payloadlen` is the full datagram length even when the buffer's
        payload room was smaller; the copied bytes are capped at the
        room and the header's flags carry MSG_TRUNC. The epoll
        emulation receives the same way.

        A full submission queue is flushed to the kernel with a
        non-waiting enter first, as every other operation does; only a
        queue still full after that flush raises.

        Args:
            fd: The socket file descriptor.
            msg: Pointer to msghdr template. Must remain valid for the
                 lifetime of the multishot operation.
            buf_group: The provided buffer group ID to select from.
            c: Pointer to the caller-owned Completion token.

        Raises:
            EOPNOTSUPP (as the socle negated-errno string) when
            `supports(DriverFeature.MULTISHOT_RECVMSG)` is False: below
            kernel 6.0 the kernel would answer -EINVAL in the CQE, and
            refusing at submission keeps the buffer ring untouched.
            EAGAIN (as the socle negated-errno string) if the ring cannot
            take the entry even after flushing; the caller may retry at
            its next flush.
        """
        if not self._supports_multishot_recvmsg:
            raise _unsupported()
        if not self._ring.sq():
            _ = self._ring.submit_and_wait(wait_nr=0)
            if not self._ring.sq():
                raise _queue_full()
        var sq = self._ring.unsynced_sq()
        var msg_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(msg)
        )
        _ = RecvMsg(sq.__next__(), fd, msg_ptr)
            .recv_flags(UInt32(MSG_TRUNC))
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(UInt64(Int(c)))

    def sq_space(mut self) -> Int:
        """Return the number of available submission queue slots.

        Syncs the SQ head from the kernel and returns the count of
        entries available for new submissions.

        Returns:
            The number of SQ entries currently available for submission.
        """
        return len(self._ring.sq())

    def backend(self) -> Backend:
        """Return Backend.IO_URING."""
        return Backend.IO_URING

    def setup_flags(self) -> IoUringSetupFlags:
        """Return the io_uring setup flags requested at construction.

        Read-only, exposed so tests can confirm a specific flag (e.g.
        `IORING_SETUP_NO_SQARRAY`) was actually requested from the
        kernel, without reaching into the ring's internals.

        Returns:
            The flags passed to `io_uring_setup` when this driver's
            ring was created.
        """
        return self._setup_flags

    def supports(self, feature: DriverFeature) -> Bool:
        """Return whether this kernel provides `feature` natively.

        Answers come from facts read at construction; nothing is
        submitted here.

        Args:
            feature: The capability to query.

        Returns:
            True if the feature can be used on this driver.
        """
        if feature is DriverFeature.MULTISHOT_RECVMSG:
            return self._supports_multishot_recvmsg
        if feature is DriverFeature.BUFFER_RING:
            return self._supports_buffer_ring
        if feature is DriverFeature.TIMEOUT_ARG:
            return self._supports_timeout_arg
        if feature is DriverFeature.FILE_READ:
            return True
        if feature is DriverFeature.FILE_WRITE:
            return True
        if feature is DriverFeature.FILE_FSYNC:
            return True
        return False

    def register_buf_ring(
        mut self,
        buf_base: Pointer[UInt8, MutUntrackedOrigin],
        buf_size: UInt32,
        count: Int,
        group_id: UInt16,
    ) raises -> BufRing:
        """Register a user-mapped provided-buffer ring (since kernel 5.19).

        Returning a consumed buffer to the ring is a userspace store on
        `BufRing.add_buffer(buf_id)` -- no SQE, no syscall, no kernel
        buffer-pool tree. Recommended for hot recv paths where the
        SQE-per-reprovide cost of the older `provide_buffers` path
        dominates.

        The ring requires a power-of-2 number of slots; `count` is
        rounded up if needed. Only `count` entries are populated,
        so `buf_base` must hold at least `count * buf_size` bytes. The
        ring memory is allocated page-aligned, as the kernel requires
        of `ring_addr`.

        Args:
            buf_base: Base pointer for the data buffers.
            buf_size: Size of each individual data buffer in bytes.
            count: Number of buffers to populate.
            group_id: Buffer group ID to register under.

        Returns:
            A populated BufRing ready for multishot recv operations.

        Raises:
            EOPNOTSUPP (as the socle negated-errno string) when
            `supports(DriverFeature.BUFFER_RING)` is False (kernel below
            5.19); otherwise whatever `io_uring_register` raises. Unlike
            `multishot_recvmsg`'s submitted op, this call reaches the
            kernel via `io_uring_register` directly, so an unsupported
            kernel would answer EINVAL synchronously here rather than
            deep in a CQE.
        """
        if not self._supports_buffer_ring:
            raise _unsupported()
        var entries = UInt32(_next_pow2(count))
        debug_assert(
            Int(entries) <= Int(UInt32.MAX) // _IO_URING_BUF_SIZE,
            "ring too large",
        )
        # The kernel rejects a ring whose address is not page-aligned
        # (EINVAL), so the ring memory is aligned explicitly rather than
        # relying on where the allocator happens to place a small block.
        var ring_bytes = Int(entries) * _IO_URING_BUF_SIZE
        var ring_mem = _heap_alloc[UInt8](
            ring_bytes, alignment=Int(get_page_size())
        ).as_unsafe_any_origin()
        for i in range(ring_bytes):
            ring_mem[unsafe_offset=i] = UInt8(0)

        var ring_mem_ut = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(ring_mem)
        )
        var buf_base_ut = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(buf_base)
        )
        var bring = BufRing(
            ring_mem_ut,
            entries,
            group_id,
            buf_base_ut,
            buf_size,
            UInt32(count),
        )

        var reg = IoUringBufReg(
            ring_addr=UInt64(Int(ring_mem)),
            ring_entries=entries,
            bgid=group_id,
        )
        var arg = reg.as_register_arg(
            unsafe_opcode=IoUringRegisterOp.REGISTER_PBUF_RING
        )
        _ = self._ring.register(arg)

        bring.populate_initial()
        return bring^

    def unregister_buf_ring(mut self, group_id: UInt16) raises:
        """Tear down a registered buffer ring.

        Args:
            group_id: The buffer group ID to unregister (use `BufRing.bgid`).
        """
        var reg = IoUringBufReg(bgid=group_id)
        var arg = reg.as_register_arg(
            unsafe_opcode=IoUringRegisterOp.UNREGISTER_PBUF_RING
        )
        _ = self._ring.register(arg)

    # ── Buffer group table ───────────────────────────────────────────────

    def _find_group(self, group_id: UInt16) -> Int:
        """Return the table index of `group_id`, or -1.

        Args:
            group_id: The buffer group to look up.

        Returns:
            The index into `_groups`, or -1 when the id is not registered.
        """
        for i in range(len(self._groups[])):
            if self._groups[][i].bgid == group_id:
                return i
        return -1

    def register_buffer_group(
        mut self,
        base: Pointer[UInt8, MutUntrackedOrigin],
        size: UInt32,
        count: Int,
        group_id: UInt16,
    ) raises:
        """Register a buffer ring for `count` buffers of `size` bytes and keep it.

        Wraps `register_buf_ring`; the returned `BufRing` is stored in the
        table so `return_buffer` and `unregister_buffer_group` can reach
        it by id. The ring rounds `count` up to a power of two but only
        populates `count` entries, so `base` needs exactly
        `count * size` bytes.

        `count` rounded up to a power of two must not exceed 32768, the
        largest ring the kernel registers (`IO_RING_MAX_ENTRIES`); the
        check is made here so every kernel answers the same way, and
        buffer ids then always fit a `UInt16`.

        Args:
            base: Address of buffer 0; must stay valid until unregistered.
            size: Bytes per buffer.
            count: Number of buffers; rounded up, at most 32768.
            group_id: Caller-chosen group id.

        Raises:
            IOError(EINVAL) if `size` is 0, or `count` is 0 or rounds
                past 32768; checked before the ring is touched.
            IOError(EEXIST) if the id is already in the table.
            Whatever `register_buf_ring` raises otherwise.
        """
        if size <= 0:
            raise IOError(positive_errno=EINVAL)
        if count <= 0 or _next_pow2(count) > _MAX_RING_ENTRIES:
            raise IOError(positive_errno=EINVAL)
        if self._find_group(group_id) >= 0:
            raise IOError(positive_errno=EEXIST)
        var ring = self.register_buf_ring(base, size, count, group_id)
        self._groups[].append(ring^)

    def unregister_buffer_group(mut self, group_id: UInt16) raises:
        """Unregister the ring behind `group_id` and drop it from the table.

        Args:
            group_id: The group to tear down.

        The kernel call runs first; if it raises, the ring stays in the
        table so a later call can retry.

        Raises:
            IOError(ENOENT) if the id is not in the table; whatever
            `unregister_buf_ring` raises otherwise.
        """
        var idx = self._find_group(group_id)
        if idx < 0:
            raise IOError(positive_errno=ENOENT)
        self.unregister_buf_ring(group_id)
        _ = self._groups[].pop(idx)

    def return_buffer(mut self, group_id: UInt16, buf_id: UInt16):
        """Hand `buf_id` back to the kernel through the group's ring.

        A userspace store on the ring tail; no syscall. Returning to an
        unknown group is a no-op.

        Args:
            group_id: The group the buffer belongs to.
            buf_id: The buffer id from the completion flags.
        """
        var idx = self._find_group(group_id)
        if idx < 0:
            return
        self._groups[][idx].add_buffer(buf_id)

    def multishot_recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        group_id: UInt16,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a multishot recvmsg from an opaque msghdr pointer.

        The trait-shaped form of the `Pointer[msghdr, ...]` overload
        above; both queue the same operation and share its
        feature gate.

        Args:
            fd: The datagram socket.
            msg: Opaque pointer to the msghdr template; must stay valid
                 for the life of the operation.
            group_id: The provided-buffer group to select from.
            c: Pointer to the caller-owned Completion token.

        Raises:
            EOPNOTSUPP (as the socle negated-errno string) when
            `supports(DriverFeature.MULTISHOT_RECVMSG)` is False.
        """
        self.multishot_recvmsg(
            fd,
            Pointer[msghdr, MutUntrackedOrigin](unsafe_from_address=Int(msg)),
            group_id,
            c,
        )
