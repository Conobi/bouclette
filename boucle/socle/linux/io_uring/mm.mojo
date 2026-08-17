from .params import Entries
from .utils import _checked_add, _checked_mul
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.linux.io_uring.types import (
    Sqe,
    SQE,
    Cqe,
    CQE,
    IoUringParams,
    IoUringSetupFlags,
)
from boucle.socle.linux.mm import (
    mmap,
    mmap_anonymous,
    munmap,
    madvise,
    get_page_size,
    ProtFlags,
    MapFlags,
    Advice,
)
from std.sys.info import align_of, size_of
from boucle.socle.ptr import null_ptr
from std.memory import UnsafePointer


struct Region(Movable):
    var ptr: UnsafePointer[c_void, StaticConstantOrigin]
    var len: UInt

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    @always_inline
    def __init__(out self, *, fd: Int32, offset: UInt64, len: UInt) raises:
        self.ptr = mmap(
            unsafe_ptr=null_ptr[c_void, StaticConstantOrigin](),
            len=len,
            prot=ProtFlags.READ | ProtFlags.WRITE,
            flags=MapFlags.SHARED | MapFlags.POPULATE,
            fd=fd,
            offset=offset,
        )
        if Int(self.ptr) == 0:
            raise "mmap returned null pointer"
        self.len = len

    @always_inline
    def __init__[
        is_shared: Bool = True
    ](out self, *, len: UInt, flags: MapFlags) raises:
        self.ptr = mmap_anonymous(
            len=len,
            prot=ProtFlags.READ | ProtFlags.WRITE,
            flags=MapFlags.SHARED if is_shared else MapFlags.PRIVATE
            | MapFlags.POPULATE
            | flags,
        )
        if Int(self.ptr) == 0:
            raise "mmap returned null pointer"
        self.len = len

    @always_inline
    def __del__(deinit self):
        try:
            munmap(unsafe_ptr=self.ptr, len=self.len)
        except e:
            debug_assert(False, "Region.__del__: munmap failed: " + String(e))

    @always_inline
    def __init__(out self, *, deinit take: Self):
        """Moves data of an existing Region into a new one.

        Args:
            take: The existing Region.
        """
        self.ptr = take.ptr
        self.len = take.len

    # ===-------------------------------------------------------------------===#
    # Factory methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    @staticmethod
    def private(out self: Self, *, len: UInt, flags: MapFlags) raises:
        self = Self.__init__[is_shared=False](len=len, flags=flags)

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    def dontfork(self) raises:
        madvise(unsafe_ptr=self.ptr, len=self.len, advice=Advice.DONTFORK)

    @always_inline
    def unsafe_ptr[
        T: AnyType
    ](self, *, offset: UInt32, count: UInt32) raises -> UnsafePointer[T, StaticConstantOrigin]:
        comptime assert align_of[T]() > 0
        comptime assert size_of[c_void]() == 1

        if _checked_add(offset, _checked_mul(count, UInt32(size_of[T]()))) > UInt32(self.len):
            raise "offset is out of bounds"
        ptr = self.ptr + offset
        if Int(ptr) & (align_of[T]() - 1):
            raise "region is not properly aligned"
        return ptr.bitcast[T]()

    @always_inline
    def unsafe_ptr(self) -> UnsafePointer[c_void, StaticConstantOrigin]:
        return self.ptr

    @always_inline
    def unsafe_mut_ptr[T: AnyType](mut self) -> UnsafePointer[T, origin_of(self)]:
        """Returns a mutable pointer to the region memory.

        The underlying memory from mmap is always writable; this method
        provides a mutable pointer by rebinding the StaticConstantOrigin
        pointer to the Region's own mutable origin.
        """
        p8 = rebind[UnsafePointer[UInt8, origin_of(self)]](
            self.ptr.bitcast[UInt8]()
        )
        return p8.bitcast[T]()

    @always_inline
    def addr(self) -> UInt64:
        return UInt64(Int(self.ptr))


struct MemoryMapping[sqe: SQE, cqe: CQE](Movable):
    var sqes_mem: Region
    var sq_cq_mem: Region

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    @always_inline
    def __init__(out self, *, var sqes_mem: Region, var sq_cq_mem: Region):
        self.sqes_mem = sqes_mem^
        self.sq_cq_mem = sq_cq_mem^

    def __init__(out self, sq_entries: UInt32, mut params: IoUringParams) raises:
        entries = Entries(
            sq_entries=sq_entries,
            flags=params.flags.value,
            cq_entries_param=params.cq_entries,
        )
        var page_size = UInt32(get_page_size())
        sqes_size = _checked_mul(entries.sq_entries, UInt32(Self.sqe.size))
        sq_array_size = (
            UInt32(0) if params.flags
            & IoUringSetupFlags.NO_SQARRAY else _checked_mul(entries.sq_entries, UInt32(size_of[UInt32]()))
        )
        sq_cq_size = _checked_add(
            _checked_add(
                UInt32(Self.cqe.rings_size),
                _checked_mul(entries.cq_entries, UInt32(Self.cqe.size)),
            ),
            sq_array_size,
        )

        comptime HUGE_PAGE_SIZE = 1 << 21
        if sqes_size > HUGE_PAGE_SIZE or sq_cq_size > HUGE_PAGE_SIZE:
            raise "ENOMEM"

        flags = MapFlags()
        if sqes_size <= page_size:
            sqes_size = page_size
        else:
            sqes_size = HUGE_PAGE_SIZE
            flags |= MapFlags.HUGETLB | MapFlags.HUGE_2MB

        self.sqes_mem = Region(
            len=UInt(sqes_size), flags=flags
        )

        flags = MapFlags()
        if sq_cq_size <= page_size:
            sq_cq_size = page_size
        else:
            sq_cq_size = HUGE_PAGE_SIZE
            flags |= MapFlags.HUGETLB | MapFlags.HUGE_2MB

        self.sq_cq_mem = Region(
            len=UInt(sq_cq_size), flags=flags
        )

        params.cq_off.user_addr = self.sq_cq_mem.addr()
        params.sq_off.user_addr = self.sqes_mem.addr()

    @always_inline
    def __init__(out self, *, deinit take: Self):
        """Moves data of an existing MemoryMapping into a new one.

        Args:
            take: The existing MemoryMapping.
        """
        self.sqes_mem = take.sqes_mem^
        self.sq_cq_mem = take.sq_cq_mem^

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    def dontfork(self) raises:
        self.sqes_mem.dontfork()
        self.sq_cq_mem.dontfork()
