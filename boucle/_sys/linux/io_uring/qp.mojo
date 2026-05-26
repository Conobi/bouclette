from .cq import Cq, CqPtr
from .sq import Sq, SqPtr
from .modes import PollingMode, NOPOLL, IOPOLL, SQPOLL
from .mm import MemoryMapping, Region
from .utils import _checked_add, _checked_mul
from .params import Params
from boucle._sys.linux.io_uring.types import (
    Sqe,
    SQE,
    SQE64,
    Cqe,
    CQE,
    CQE16,
    IoUringParams,
    IoUringSetupFlags,
    IoUringFeatureFlags,
    IoUringSqFlags,
    IoUringEnterFlags,
    OwnedFd,
    EnterArg,
    NO_ENTER_ARG,
    RegisterArg,
    io_uring_setup,
    io_uring_register,
    io_uring_enter,
)
from boucle._sys.linux.raw import (
    IORING_OFF_SQ_RING,
    IORING_OFF_SQES,
)
from std.sys.info import size_of
from std.sys.intrinsics import unlikely


struct IoUring[
    sqe: SQE = SQE64,
    cqe: CQE = CQE16,
    polling: PollingMode = NOPOLL,
    *,
    is_registered: Bool = True,
](Movable):
    var _sq: Sq[Self.sqe, Self.polling]
    var _cq: Cq[Self.cqe]
    var fd: OwnedFd[Self.is_registered]
    var mem: MemoryMapping[Self.sqe, Self.cqe]

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    def __init__(out self, *, sq_entries: UInt32) raises:
        self = Self(sq_entries=sq_entries, params=Params())

    def __init__(out self, *, sq_entries: UInt32, params: Params) raises:
        io_uring_params = IoUringParams()
        io_uring_params.cq_entries = params._cq_entries
        io_uring_params.flags = params.flags
        io_uring_params.sq_thread_cpu = params.sq_thread_cpu
        io_uring_params.sq_thread_idle = params.sq_thread_idle
        io_uring_params.wq_fd = params.wq_fd
        self = Self(sq_entries=sq_entries, params=io_uring_params)
        if params.is_dontfork():
            self.mem.dontfork()

    def __init__(
        out self, *, sq_entries: UInt32, mut params: IoUringParams
    ) raises:
        comptime assert Self.polling is not SQPOLL, "SQPOLL mode is disabled because Mojo does not have atomic fence"
        comptime flags = Self.sqe.setup_flags | Self.cqe.setup_flags | Self.polling.setup_flags
        params.flags |= flags

        comptime if Self.is_registered:
            self.mem = MemoryMapping[Self.sqe, Self.cqe](sq_entries, params)
            self.fd = io_uring_setup[Self.is_registered](sq_entries, params)
        else:
            fd = io_uring_setup[Self.is_registered](sq_entries, params)
            if not params.features & IoUringFeatureFlags.SINGLE_MMAP:
                raise "system outdated"
            sq_len = _checked_add(params.sq_off.array, _checked_mul(params.sq_entries, UInt32(size_of[UInt32]())))
            cq_len = _checked_add(params.cq_off.cqes, _checked_mul(params.cq_entries, UInt32(Self.cqe.size)))
            sq_cq_mem = Region(
                fd=fd.unsafe_fd(),
                offset=IORING_OFF_SQ_RING,
                len=UInt(max(sq_len, cq_len)),
            )
            sqes_mem = Region(
                fd=fd.unsafe_fd(),
                offset=IORING_OFF_SQES,
                len=UInt(_checked_mul(params.sq_entries, UInt32(Self.sqe.size))),
            )
            self.fd = fd^
            self.mem = MemoryMapping[Self.sqe, Self.cqe](
                sqes_mem=sqes_mem^, sq_cq_mem=sq_cq_mem^
            )

        self._sq = Sq[Self.sqe, Self.polling](
            params,
            sq_cq_mem=self.mem.sq_cq_mem,
            sqes_mem=self.mem.sqes_mem,
        )
        self._cq = Cq[Self.cqe](params, sq_cq_mem=self.mem.sq_cq_mem)

    def __del__(deinit self):
        # Ensure that `MemoryMapping` is released before `self.fd`
        # as it may depend on it.
        self.mem^.__del__()
        self.fd^.__del__()

    @always_inline
    def __init__(out self, *, deinit take: Self):
        """Moves data of an existing IoUring into a new one.

        Args:
            take: The existing IoUring.
        """
        self._sq = take._sq^
        self._cq = take._cq^
        self.fd = take.fd^
        self.mem = take.mem^

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    def sq(
        mut self,
    ) -> SqPtr[Self.sqe, Self.polling, origin_of(self._sq)]:
        self.sync_sq_head()
        return self.unsynced_sq()

    @always_inline
    def unsynced_sq(
        mut self,
    ) -> SqPtr[Self.sqe, Self.polling, origin_of(self._sq)]:
        return self._sq

    @always_inline
    def sync_sq_head(mut self):
        self._sq.sync_head()

    @always_inline
    def submit_and_wait(mut self, *, wait_nr: UInt32) raises -> UInt32:
        return self.submit_and_wait(wait_nr=wait_nr, arg=NO_ENTER_ARG)

    @always_inline
    def submit_and_wait(
        mut self, *, wait_nr: UInt32, arg: EnterArg
    ) raises -> UInt32:
        submitted = self._sq.flush()
        flags = IoUringEnterFlags()

        cq_needs_enter = wait_nr > 0 or self.cq_needs_enter()

        if self.sq_needs_enter(submitted, flags) or cq_needs_enter:
            if cq_needs_enter:
                flags |= IoUringEnterFlags.GETEVENTS
            return self.enter(
                to_submit=submitted, min_complete=wait_nr, flags=flags, arg=arg
            )

        return submitted

    @always_inline
    def sq_needs_enter(
        self, submitted: UInt32, mut flags: IoUringEnterFlags
    ) -> Bool:
        comptime if Self.polling is not SQPOLL:
            return True

        if submitted == 0:
            return False

        # FIXME: Need to use atomic fence here to ensure the kernel
        # can see the store to the `self._sq._tail` before we read the flags.
        # [Reference]: https://github.com/modularml/mojo/issues/3162.

        if unlikely(Bool(self._sq.flags() & IoUringSqFlags.NEED_WAKEUP)):
            flags |= IoUringEnterFlags.SQ_WAKEUP
            return True

        return False

    @always_inline
    def cq(
        mut self, *, wait_nr: UInt32
    ) raises -> CqPtr[Self.cqe, origin_of(self._cq)]:
        return self.cq(wait_nr=wait_nr, arg=NO_ENTER_ARG)

    @always_inline
    def cq(
        mut self, *, wait_nr: UInt32, arg: EnterArg
    ) raises -> CqPtr[Self.cqe, origin_of(self._cq)]:
        self.flush_cq(wait_nr, arg)
        return self._cq

    @always_inline
    def flush_cq(mut self, wait_nr: UInt32, arg: EnterArg) raises:
        self._cq.sync_tail()
        if not self._cq and (wait_nr > 0 or self.cq_needs_flush()):
            _ = self.enter(
                to_submit=0,
                min_complete=wait_nr,
                flags=IoUringEnterFlags.GETEVENTS,
                arg=arg,
            )
            self._cq.sync_tail()

    @always_inline
    def cq_needs_flush(self) -> Bool:
        return Bool(
            self._sq.flags()
            & (IoUringSqFlags.CQ_OVERFLOW | IoUringSqFlags.TASKRUN)
        )

    @always_inline
    def cq_needs_enter(self) -> Bool:
        comptime if Self.polling is IOPOLL:
            return True
        else:
            return self.cq_needs_flush()

    @always_inline
    def register(self, arg: RegisterArg) raises -> UInt32:
        return io_uring_register(self.fd, arg)

    @always_inline
    def enter(
        self,
        *,
        to_submit: UInt32,
        min_complete: UInt32,
        flags: IoUringEnterFlags,
        arg: EnterArg,
    ) raises -> UInt32:
        return io_uring_enter(
            self.fd,
            to_submit=to_submit,
            min_complete=min_complete,
            flags=flags,
            arg=arg,
        )
