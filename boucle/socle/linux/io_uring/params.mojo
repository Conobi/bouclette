from .utils import _next_power_of_two
from boucle.socle.linux.raw import (
    IORING_SETUP_CQSIZE,
    IORING_SETUP_CLAMP,
    IORING_SETUP_NO_SQARRAY,
)

comptime SQ_ENTRIES_MAX = UInt32(32768)
comptime CQ_ENTRIES_MAX = UInt32(SQ_ENTRIES_MAX * 2)


struct Params(Defaultable, ImplicitlyCopyable, Movable):
    var flags: UInt32
    var _cq_entries: UInt32
    var sq_thread_cpu: UInt32
    var sq_thread_idle: UInt32
    var wq_fd: UInt32
    var _dontfork: Bool

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    def __init__(out self):
        self.flags = IORING_SETUP_NO_SQARRAY
        self._cq_entries = 0
        self.sq_thread_cpu = 0
        self.sq_thread_idle = 0
        self.wq_fd = 0
        self._dontfork = False

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    # TODO: Use NonZeroUInt32 value type.
    def cq_entries(mut self, value: UInt32) -> ref [self] Self:
        self._cq_entries = value
        self.flags |= IORING_SETUP_CQSIZE
        return self

    def clamp(mut self) -> ref [self] Self:
        self.flags |= IORING_SETUP_CLAMP
        return self

    def dontfork(mut self) -> ref [self] Self:
        self._dontfork = True
        return self

    def is_dontfork(self) -> Bool:
        return self._dontfork


struct Entries(TrivialRegisterPassable):
    var sq_entries: UInt32
    var cq_entries: UInt32

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    def __init__(out self, *, sq_entries: UInt32, flags: UInt32, cq_entries_param: UInt32) raises:
        """Compute validated SQ and CQ entry counts.

        Args:
            sq_entries: Requested number of submission queue entries.
            flags: Setup flags (raw UInt32, will be matched against IORING_SETUP_* constants).
            cq_entries_param: Requested CQ entries (only used when IORING_SETUP_CQSIZE is set in flags).

        Raises:
            If validation fails (zero entries, exceeds max without CLAMP, etc.).
        """
        if sq_entries == 0:
            raise "EINVAL"

        self.sq_entries = _next_power_of_two(sq_entries)
        if self.sq_entries > SQ_ENTRIES_MAX:
            if not (flags & IORING_SETUP_CLAMP):
                raise "EINVAL"
            self.sq_entries = SQ_ENTRIES_MAX

        if flags & IORING_SETUP_CQSIZE:
            if cq_entries_param == 0:
                raise "EINVAL"
            self.cq_entries = _next_power_of_two(cq_entries_param)
            if self.cq_entries > CQ_ENTRIES_MAX:
                if not (flags & IORING_SETUP_CLAMP):
                    raise "EINVAL"
                self.cq_entries = CQ_ENTRIES_MAX
            if self.cq_entries < self.sq_entries:
                raise "EINVAL"
        else:
            self.cq_entries = self.sq_entries * 2
