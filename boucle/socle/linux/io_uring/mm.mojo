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
from std.memory import Pointer


@always_inline("nodebug")
def _round_up_to_page(len: UInt32, page_size: UInt32) raises -> UInt32:
    """Rounds `len` up to the next multiple of `page_size`.

    Args:
        len: Byte length to round.
        page_size: Page size in bytes; must be a power of two.

    Returns:
        The smallest multiple of `page_size` that is `>= len`.

    Raises:
        If the rounding would overflow `UInt32`.
    """
    debug_assert(
        page_size != 0 and (page_size & (page_size - 1)) == 0,
        "page_size must be a power of two",
    )
    return _checked_add(len, page_size - 1) & ~(page_size - 1)


struct Region(Movable):
    var ptr: Pointer[c_void, ImmStaticOrigin]
    var len: UInt

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    @always_inline
    def __init__(out self, *, fd: Int32, offset: UInt64, len: UInt) raises:
        self.ptr = mmap(
            unsafe_ptr=null_ptr[c_void, ImmStaticOrigin](),
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
    ](out self, *, len: UInt, flags: MapFlags, fallback_len: UInt = 0) raises:
        """Maps `len` bytes of anonymous, pre-faulted, read/write memory.

        The mapping is `MAP_SHARED` (default) or `MAP_PRIVATE`, always
        `MAP_ANONYMOUS | MAP_POPULATE`, plus the caller's `flags`. This is
        the backing store for user-allocated (`IORING_SETUP_NO_MMAP`) rings.
        Huge pages are an optimisation, never a requirement: when `flags`
        request `MAP_HUGETLB` and the kernel refuses (typically `ENOMEM`
        because `vm.nr_hugepages` is 0, the default on most systems), the
        mapping is retried once with the same sharedness and `MAP_POPULATE`
        but with `MAP_HUGETLB` and the `MAP_HUGE_*` size bits cleared, and
        with `fallback_len` bytes instead of `len` when the caller gave one.
        `len` is typically rounded up to the huge-page size so the first
        attempt is well-formed; `fallback_len` lets the caller map only the
        page-rounded size it actually needs on regular pages, so a populated
        fallback does not pin a full huge page's worth of memory. `Region`
        applies no size policy of its own; `MemoryMapping` decides both
        lengths. liburing's `io_uring_alloc_huge` does not fall back and
        returns `-ENOMEM` to the application; Boucle falls back so that
        NO_MMAP rings larger than one page work without operator tuning.

        Parameters:
            is_shared: `MAP_SHARED` when True, `MAP_PRIVATE` when False.

        Args:
            len: Length of the mapping in bytes for the first attempt.
            flags: Extra `MAP_*` flags (e.g. `HUGETLB | HUGE_2MB`).
            fallback_len: Length in bytes for the regular-page retry. `0`
                (the default) reuses `len`. Ignored unless `flags` contain
                `MAP_HUGETLB`, since no retry happens otherwise.

        Raises:
            `Errno` if `mmap` fails; when huge pages were requested, only
            after the regular-page retry has also failed.
        """
        var base = (
            MapFlags.SHARED if is_shared else MapFlags.PRIVATE
        ) | MapFlags.POPULATE
        var prot = ProtFlags.READ | ProtFlags.WRITE
        var mapped_len = len
        var ptr: Pointer[c_void, ImmStaticOrigin]
        try:
            ptr = mmap_anonymous(len=len, prot=prot, flags=base | flags)
        except e:
            if not (flags & MapFlags.HUGETLB):
                raise e
            if fallback_len != 0:
                mapped_len = fallback_len
            ptr = mmap_anonymous(
                len=mapped_len,
                prot=prot,
                flags=base | flags.without_huge_pages(),
            )
        self.ptr = ptr
        if Int(self.ptr) == 0:
            raise "mmap returned null pointer"
        self.len = mapped_len

    @always_inline
    def __deinit__(deinit self):
        try:
            munmap(unsafe_ptr=self.ptr, len=self.len)
        except e:
            debug_assert(False, "Region.__deinit__: munmap failed: " + String(e))

    @always_inline
    def __init__(out self, *, deinit move: Self):
        """Moves data of an existing Region into a new one.

        Args:
            move: The existing Region.
        """
        self.ptr = move.ptr
        self.len = move.len

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
    ](self, *, offset: UInt32, count: UInt32) raises -> Pointer[T, ImmStaticOrigin]:
        comptime assert align_of[T]() > 0
        comptime assert size_of[c_void]() == 1

        if _checked_add(offset, _checked_mul(count, UInt32(size_of[T]()))) > UInt32(self.len):
            raise "offset is out of bounds"
        var ptr = self.ptr.unsafe_offset(offset)
        if Int(ptr) & (align_of[T]() - 1):
            raise "region is not properly aligned"
        return ptr.unsafe_bitcast[T]()

    @always_inline
    def unsafe_ptr(self) -> Pointer[c_void, ImmStaticOrigin]:
        return self.ptr

    @always_inline
    def unsafe_mut_ptr[T: AnyType](mut self) -> Pointer[T, origin_of(self)]:
        """Returns a mutable pointer to the region memory.

        The underlying memory from mmap is always writable; this method
        provides a mutable pointer by rebinding the ImmStaticOrigin
        pointer to the Region's own mutable origin.
        """
        var p8 = rebind[Pointer[UInt8, origin_of(self)]](
            self.ptr.unsafe_bitcast[UInt8]()
        )
        return p8.unsafe_bitcast[T]()

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
        """Allocates the SQE array and the SQ/CQ ring for a NO_MMAP io_uring.

        The needed byte size of each region is derived from the rounded
        entry counts (`Entries`), the SQE/CQE layouts and, unless
        `IORING_SETUP_NO_SQARRAY` is set, the SQ index array. A region that
        fits in one page is mapped as exactly one page on regular pages. A
        larger region (at most one 2 MiB huge page; bigger rings raise
        `ENOMEM`) is first requested as a single `HUGETLB | HUGE_2MB` page,
        with `fallback_len` set to the needed size rounded up to the runtime
        page size, so that when no huge pages are reserved `Region` maps and
        populates only the pages the ring uses rather than 2 MiB. The kernel
        never sees the mapping length: `sq_off.user_addr` / `cq_off.user_addr`
        carry only the base addresses and the kernel pins exactly the pages
        it needs, so `Region.len` (used for bounds checks, `madvise` and
        `munmap`) is the sole owner of the mapped length. Note that kernels
        6.5 to 6.11 require a multi-page NO_MMAP ring to be a single folio,
        so on those kernels the regular-page fallback is rejected with
        `EINVAL` by `io_uring_setup`; 6.12+ accepts any page-aligned range.

        Args:
            sq_entries: Requested number of submission queue entries.
            params: Setup parameters; `cq_off.user_addr` and
                `sq_off.user_addr` are filled with the region addresses.

        Raises:
            `ENOMEM` if a region would exceed one huge page; `Errno` if
            the underlying `mmap` fails on both attempts.
        """
        var entries = Entries(
            sq_entries=sq_entries,
            flags=params.flags.value,
            cq_entries_param=params.cq_entries,
        )
        var page_size = UInt32(get_page_size())
        var sqes_size = _checked_mul(entries.sq_entries, UInt32(Self.sqe.size))
        var sq_array_size = (
            UInt32(0) if params.flags
            & IoUringSetupFlags.NO_SQARRAY else _checked_mul(entries.sq_entries, UInt32(size_of[UInt32]()))
        )
        var sq_cq_size = _checked_add(
            _checked_add(
                UInt32(Self.cqe.rings_size),
                _checked_mul(entries.cq_entries, UInt32(Self.cqe.size)),
            ),
            sq_array_size,
        )

        if sqes_size > Self.HUGE_PAGE_SIZE or sq_cq_size > Self.HUGE_PAGE_SIZE:
            raise "ENOMEM"

        self.sqes_mem = Self._map_ring(needed_len=sqes_size, page_size=page_size)
        self.sq_cq_mem = Self._map_ring(needed_len=sq_cq_size, page_size=page_size)

        params.cq_off.user_addr = self.sq_cq_mem.addr()
        params.sq_off.user_addr = self.sqes_mem.addr()

    comptime HUGE_PAGE_SIZE = UInt32(1 << 21)
    """Size of the huge page requested for rings larger than one page."""

    @staticmethod
    def _map_ring(*, needed_len: UInt32, page_size: UInt32) raises -> Region:
        """Maps one ring region according to the size policy described above.

        Args:
            needed_len: Bytes the ring actually uses; at most
                `HUGE_PAGE_SIZE`.
            page_size: The runtime page size (a power of two).

        Returns:
            A one-page region when `needed_len` fits in a page; otherwise a
            2 MiB huge-page region, or on fallback a regular-page region of
            `needed_len` rounded up to `page_size`.

        Raises:
            `Errno` if `mmap` fails.
        """
        if needed_len <= page_size:
            return Region(len=UInt(page_size), flags=MapFlags())
        return Region(
            len=UInt(Self.HUGE_PAGE_SIZE),
            flags=MapFlags.HUGETLB | MapFlags.HUGE_2MB,
            fallback_len=UInt(_round_up_to_page(needed_len, page_size)),
        )

    @always_inline
    def __init__(out self, *, deinit move: Self):
        """Moves data of an existing MemoryMapping into a new one.

        Args:
            move: The existing MemoryMapping.
        """
        self.sqes_mem = move.sqes_mem^
        self.sq_cq_mem = move.sq_cq_mem^

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    def dontfork(self) raises:
        self.sqes_mem.dontfork()
        self.sq_cq_mem.dontfork()
