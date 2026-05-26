from boucle._sys.linux.raw.ctypes import c_uint, c_void
from boucle._sys.linux.errno import unsafe_decode_ptr, unsafe_decode_none
from boucle._sys.linux.raw import (
    __NR_mmap,
    __NR_mprotect,
    __NR_munmap,
    __NR_madvise,
    MAP_SHARED,
    MAP_SHARED_VALIDATE,
    MAP_PRIVATE,
    MAP_DENYWRITE,
    MAP_FIXED,
    MAP_FIXED_NOREPLACE,
    MAP_GROWSDOWN,
    MAP_HUGETLB,
    MAP_HUGE_2MB,
    MAP_HUGE_1GB,
    MAP_LOCKED,
    MAP_NORESERVE,
    MAP_POPULATE,
    MAP_STACK,
    MAP_SYNC,
    MAP_UNINITIALIZED,
    MAP_ANONYMOUS,
    PROT_NONE,
    PROT_READ,
    PROT_WRITE,
    PROT_EXEC,
    MADV_NORMAL,
    MADV_RANDOM,
    MADV_SEQUENTIAL,
    MADV_WILLNEED,
    MADV_DONTNEED,
    MADV_FREE,
    MADV_REMOVE,
    MADV_DONTFORK,
    MADV_DOFORK,
    MADV_HWPOISON,
    MADV_SOFT_OFFLINE,
    MADV_MERGEABLE,
    MADV_UNMERGEABLE,
    MADV_HUGEPAGE,
    MADV_NOHUGEPAGE,
    MADV_DONTDUMP,
    MADV_DODUMP,
    MADV_WIPEONFORK,
    MADV_KEEPONFORK,
    MADV_COLD,
    MADV_PAGEOUT,
    MADV_POPULATE_READ,
    MADV_POPULATE_WRITE,
    MADV_DONTNEED_LOCKED,
    MADV_COLLAPSE,
)
from boucle._sys.linux.raw import syscall
from boucle._sys.linux.raw.utils import is_64bit
from std.ffi import external_call
from std.memory import UnsafePointer


@always_inline
def get_page_size() -> UInt:
    """Returns the system page size via libc getpagesize()."""
    return UInt(external_call["getpagesize", Int32]())


@always_inline
def mmap(
    *,
    unsafe_ptr: UnsafePointer[c_void, StaticConstantOrigin],
    len: UInt,
    prot: ProtFlags,
    flags: MapFlags,
    fd: Int32,
    offset: UInt64,
) raises -> UnsafePointer[c_void, StaticConstantOrigin]:
    """Unsafely creates a file-backed memory mapping.
    [Linux]: https://man7.org/linux/man-pages/man2/mmap.2.html.

    Args:
        unsafe_ptr: The starting address hint.
        len: The length of the mapping.
        prot: The bitmask of the `ProtFlags` values.
        flags: The bitmask of the `MapFlags` values.
        fd: The file descriptor that refers to the file (or other object)
            containing the mapping.
        offset: The offset in the file (or other object) referred to by `fd`.

    Returns:
        Pointer to the mapped area.

    Raises:
        `Errno` if the syscall returned an error.

    Safety:
        Unsafe pointers and lots of special semantics.
    """
    comptime assert is_64bit()

    var res = syscall[__NR_mmap, UnsafePointer[c_void, StaticConstantOrigin]](
        unsafe_ptr, len, prot, flags, fd, offset
    )
    unsafe_decode_ptr(res)
    return res


@always_inline
def mmap_anonymous(
    *,
    len: UInt,
    prot: ProtFlags,
    flags: MapFlags,
) raises -> UnsafePointer[c_void, StaticConstantOrigin]:
    """Unsafely creates an anonymous memory mapping.
    [Linux]: https://man7.org/linux/man-pages/man2/mmap.2.html.

    The `unsafe_ptr` hint is set to null (kernel chooses the address).
    The `MAP_ANONYMOUS` flag is always included.

    Args:
        len: The length of the mapping.
        prot: The bitmask of the `ProtFlags` values.
        flags: The bitmask of the `MapFlags` values.

    Returns:
        Pointer to the mapped area.

    Raises:
        `Errno` if the syscall returned an error.

    Safety:
        Unsafe pointers and lots of special semantics.
    """
    comptime assert is_64bit()

    var null_ptr = UnsafePointer[c_void, StaticConstantOrigin](unsafe_from_address=0)
    var res = syscall[__NR_mmap, UnsafePointer[c_void, StaticConstantOrigin]](
        null_ptr, len, prot, flags | MapFlags(MAP_ANONYMOUS), Int32(-1), UInt64(0)
    )
    unsafe_decode_ptr(res)
    return res


@always_inline
def munmap(*, unsafe_ptr: UnsafePointer[c_void, StaticConstantOrigin], len: UInt) raises:
    """Unsafely removes a memory mapping.
    [Linux]: https://man7.org/linux/man-pages/man2/mmap.2.html.

    Args:
        unsafe_ptr: The starting address of the range for which
                    the mapping should be removed.
        len: The length of the address range for which the mapping
             should be removed.

    Raises:
        `Errno` if the syscall returned an error.

    Safety:
        Unsafe pointers and lots of special semantics.
    """
    var res = syscall[__NR_munmap, Scalar[DType.int64]](unsafe_ptr, len)
    unsafe_decode_none(res)


@always_inline
def madvise(
    *, unsafe_ptr: UnsafePointer[c_void, StaticConstantOrigin], len: UInt, advice: Advice
) raises:
    """Unsafely declares the expected access pattern for the memory mapping.
    [Linux]: https://man7.org/linux/man-pages/man2/madvise.2.html.

    Args:
        unsafe_ptr: Starting address of the mapping range.
        len: The length of the mapping address range.
        advice: One of the `Advice` values.

    Raises:
        `Errno` if the syscall returned an error.

    Safety:
        `unsafe_ptr` must be a valid pointer to memory that is appropriate
         to call `madvise` on. Some forms of `advice` may mutate the memory
         or evoke a variety of side-effects on the mapping and/or the file.
    """
    var res = syscall[__NR_madvise, Scalar[DType.int64]](unsafe_ptr, len, advice)
    unsafe_decode_none(res)


@always_inline
def mprotect(
    *, unsafe_ptr: UnsafePointer[c_void, StaticConstantOrigin], len: UInt, prot: ProtFlags
) raises:
    """Changes the access protections for a memory region.
    [Linux]: https://man7.org/linux/man-pages/man2/mprotect.2.html.

    Args:
        unsafe_ptr: Start of the memory region (must be page-aligned).
        len: Length of the region.
        prot: New protection flags.

    Raises:
        If the syscall returned an error.
    """
    var res = syscall[__NR_mprotect, Scalar[DType.int64]](unsafe_ptr, len, prot)
    unsafe_decode_none(res)


struct MapFlags(TrivialRegisterPassable, Defaultable):
    """`MAP_*` flags for use with `mmap` and `mmap_anonymous`."""

    comptime SHARED = Self(MAP_SHARED)
    comptime SHARED_VALIDATE = Self(MAP_SHARED_VALIDATE)
    comptime PRIVATE = Self(MAP_PRIVATE)
    comptime DENYWRITE = Self(MAP_DENYWRITE)
    comptime FIXED = Self(MAP_FIXED)
    comptime FIXED_NOREPLACE = Self(MAP_FIXED_NOREPLACE)
    comptime GROWSDOWN = Self(MAP_GROWSDOWN)
    comptime HUGETLB = Self(MAP_HUGETLB)
    comptime HUGE_2MB = Self(MAP_HUGE_2MB)
    comptime HUGE_1GB = Self(MAP_HUGE_1GB)
    comptime LOCKED = Self(MAP_LOCKED)
    comptime NORESERVE = Self(MAP_NORESERVE)
    comptime POPULATE = Self(MAP_POPULATE)
    comptime STACK = Self(MAP_STACK)
    comptime SYNC = Self(MAP_SYNC)
    comptime UNINITIALIZED = Self(MAP_UNINITIALIZED)

    var value: c_uint

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: c_uint):
        self.value = value

    @always_inline("nodebug")
    def __or__(self, rhs: Self) -> Self:
        """Returns `self | rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self | rhs`.
        """
        return self.value | rhs.value

    @always_inline("nodebug")
    def __ior__(mut self, rhs: Self):
        """Computes `self | rhs` and saves the result in self.

        Args:
            rhs: The RHS value.
        """
        self = self | rhs


struct ProtFlags(TrivialRegisterPassable, Defaultable):
    """`PROT_*` flags for use with `mmap`."""

    comptime NONE = Self(PROT_NONE)
    comptime READ = Self(PROT_READ)
    comptime WRITE = Self(PROT_WRITE)
    comptime EXEC = Self(PROT_EXEC)

    var value: c_uint

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: c_uint):
        self.value = value

    @always_inline("nodebug")
    def __or__(self, rhs: Self) -> Self:
        """Returns `self | rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self | rhs`.
        """
        return self.value | rhs.value


struct Advice(TrivialRegisterPassable):
    """`POSIX_MADV_*` constants for use with `madvise`."""

    comptime NORMAL = Self(unsafe_id=MADV_NORMAL)
    comptime RANDOM = Self(unsafe_id=MADV_RANDOM)
    comptime SEQUENTIAL = Self(unsafe_id=MADV_SEQUENTIAL)
    comptime WILLNEED = Self(unsafe_id=MADV_WILLNEED)
    comptime DONTNEED = Self(unsafe_id=MADV_DONTNEED)
    comptime FREE = Self(unsafe_id=MADV_FREE)
    comptime REMOVE = Self(unsafe_id=MADV_REMOVE)
    comptime DONTFORK = Self(unsafe_id=MADV_DONTFORK)
    comptime DOFORK = Self(unsafe_id=MADV_DOFORK)
    comptime HWPOISON = Self(unsafe_id=MADV_HWPOISON)
    comptime SOFT_OFFLINE = Self(unsafe_id=MADV_SOFT_OFFLINE)
    comptime MERGEABLE = Self(unsafe_id=MADV_MERGEABLE)
    comptime UNMERGEABLE = Self(unsafe_id=MADV_UNMERGEABLE)
    comptime HUGEPAGE = Self(unsafe_id=MADV_HUGEPAGE)
    comptime NOHUGEPAGE = Self(unsafe_id=MADV_NOHUGEPAGE)
    comptime DONTDUMP = Self(unsafe_id=MADV_DONTDUMP)
    comptime DODUMP = Self(unsafe_id=MADV_DODUMP)
    comptime WIPEONFORK = Self(unsafe_id=MADV_WIPEONFORK)
    comptime KEEPONFORK = Self(unsafe_id=MADV_KEEPONFORK)
    comptime COLD = Self(unsafe_id=MADV_COLD)
    comptime PAGEOUT = Self(unsafe_id=MADV_PAGEOUT)
    comptime POPULATE_READ = Self(unsafe_id=MADV_POPULATE_READ)
    comptime POPULATE_WRITE = Self(unsafe_id=MADV_POPULATE_WRITE)
    comptime DONTNEED_LOCKED = Self(unsafe_id=MADV_DONTNEED_LOCKED)
    comptime COLLAPSE = Self(unsafe_id=MADV_COLLAPSE)

    var id: c_uint

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_id: c_uint):
        self.id = unsafe_id
