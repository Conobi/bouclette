"""RAII platform backend for coroutine stacks on Linux x86_64.

Encapsulates all platform-specific unsafe operations for stackful coroutines:
mmap/munmap for guard-page-protected stacks, ucontext_t allocation and
register setup, and context switching via swapcontext.

Three layered RAII structs:
- _MappedRegion: owns an mmap'd memory region (guard page + usable stack)
- _UContext: owns a 968-byte ucontext_t buffer
- _UcontextStack: combines region + two contexts (caller + coro)
"""

from std.memory import Pointer
from boucle.socle.linux.ucontext import (
    alloc_ucontext,
    free_ucontext,
    uc_getcontext,
    uc_swapcontext,
    uc_swapcontext_unchecked,
)
from boucle.socle.linux.mm import (
    mmap_anonymous,
    mprotect,
    get_page_size,
    MapFlags,
    ProtFlags,
)
from boucle.socle.linux.raw import (
    syscall,
    __NR_munmap,
    UC_STACK_SP_OFFSET,
    UC_STACK_FLAGS_OFFSET,
    UC_STACK_SIZE_OFFSET,
    UC_GREGS_OFFSET,
    REG_RDI,
    REG_RSP,
    REG_RIP,
)
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.ptr import null_ptr


# ── _MappedRegion ──────────────────────────────────────────────────────


struct _MappedRegion(Movable):
    """Owns an mmap'd memory region with a guard page.

    Layout: [guard page (PROT_NONE)] [usable stack (RW)]
    The guard page protects against stack overflow via SIGSEGV.
    RAII: destructor calls munmap on the entire region.
    """

    var _base: Pointer[c_void, ImmStaticOrigin]
    var _total: UInt

    def __init__(out self, stack_size: UInt) raises:
        """Allocate a guard-page-protected stack region.

        Args:
            stack_size: Size of the usable stack in bytes (past the guard page).

        Raises:
            If mmap or mprotect fails, or if stack_size would overflow.
        """
        var page_size = get_page_size()
        if stack_size > UInt.MAX - page_size:
            raise "stack size overflow: too large for guard page allocation"

        var total = page_size + stack_size
        var base = mmap_anonymous(
            len=total,
            prot=ProtFlags.READ | ProtFlags.WRITE,
            flags=MapFlags.PRIVATE | MapFlags.STACK,
        )
        try:
            mprotect(unsafe_ptr=base, len=page_size, prot=ProtFlags.NONE)
        except e:
            _ = syscall[__NR_munmap, Scalar[DType.int64]](base, total)
            raise e^

        self._base = base
        self._total = total

    def __init__(out self, *, deinit move: Self):
        """Move constructor. Transfers ownership of the mapped region."""
        self._base = move._base
        self._total = move._total

    def __deinit__(deinit self):
        """Unmap the entire region (guard page + usable stack)."""
        _ = syscall[__NR_munmap, Scalar[DType.int64]](self._base, self._total)

    def usable_base(self, page_size: UInt) -> Pointer[UInt8, MutUntrackedOrigin]:
        """Return a pointer to the start of the usable stack (past the guard page).

        Args:
            page_size: System page size in bytes.

        Returns:
            Pointer to the first usable byte of the stack.
        """
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(self._base) + Int(page_size)
        )

    def usable_size(self, page_size: UInt) -> UInt:
        """Return the size of the usable stack region.

        Args:
            page_size: System page size in bytes.

        Returns:
            Size of the usable region in bytes (_total - guard page).
        """
        return self._total - page_size


# ── _UContext ──────────────────────────────────────────────────────────


struct _UContext(Movable):
    """Owns a ucontext_t buffer (968 bytes on x86_64).

    RAII: destructor frees the heap-allocated buffer.
    Provides typed methods for getcontext, stack setup, and register setup,
    hiding the raw offset arithmetic from callers.
    """

    var _buf: Pointer[UInt8, MutUntrackedOrigin]

    def __init__(out self):
        """Allocate a zeroed ucontext_t buffer."""
        self._buf = alloc_ucontext()

    def __init__(out self, *, deinit move: Self):
        """Move constructor. Transfers ownership of the buffer."""
        self._buf = move._buf

    def __deinit__(deinit self):
        """Free the ucontext_t buffer."""
        free_ucontext(self._buf)

    def getcontext(mut self) raises:
        """Initialize this ucontext_t by saving the current context.

        Must be called before set_stack/set_entry to populate the struct
        with valid initial values.

        Raises:
            If the getcontext libc call fails.
        """
        uc_getcontext(self._buf)

    def set_stack(
        mut self,
        usable_base: Pointer[UInt8, MutUntrackedOrigin],
        usable_size: UInt,
    ):
        """Write the uc_stack fields (ss_sp, ss_flags, ss_size).

        Must be called after getcontext() and before set_entry().

        Args:
            usable_base: Pointer to the start of the usable stack region.
            usable_size: Size of the usable stack region in bytes.
        """
        var ss_sp = self._buf.unsafe_offset(UC_STACK_SP_OFFSET).unsafe_bitcast[
            Pointer[UInt8, MutUntrackedOrigin]
        ]()
        ss_sp[] = usable_base
        var ss_flags = self._buf.unsafe_offset(
            UC_STACK_FLAGS_OFFSET
        ).unsafe_bitcast[Int32]()
        ss_flags[] = 0
        var ss_size = self._buf.unsafe_offset(
            UC_STACK_SIZE_OFFSET
        ).unsafe_bitcast[UInt]()
        ss_size[] = usable_size

    def set_entry(mut self, fn_addr: Int, arg_addr: Int):
        """Write the gregs for entry point, stack pointer, and first argument.

        Computes the stack pointer from the previously set uc_stack fields
        (ss_sp + ss_size), aligned per the platform ABI using arch-dispatched
        constants from abi.mojo.

        Must be called after set_stack().

        Args:
            fn_addr: Address of the entry function (written to REG_RIP).
            arg_addr: First argument value (written to REG_RDI).
        """
        # Read back stack info from uc_stack fields set by set_stack()
        var ss_sp = self._buf.unsafe_offset(UC_STACK_SP_OFFSET).unsafe_bitcast[
            Pointer[UInt8, MutUntrackedOrigin]
        ]()
        var ss_size = self._buf.unsafe_offset(
            UC_STACK_SIZE_OFFSET
        ).unsafe_bitcast[UInt]()

        from boucle.socle.linux.abi import STACK_ENTRY_OFFSET, STACK_ALIGNMENT
        var stack_top = Int(ss_sp[]) + Int(ss_size[])
        var sp = (stack_top & ~(STACK_ALIGNMENT - 1)) - STACK_ENTRY_OFFSET

        # Write gregs
        var gregs = self._buf.unsafe_offset(UC_GREGS_OFFSET).unsafe_bitcast[
            Int64
        ]()
        gregs[unsafe_offset=REG_RIP] = Int64(fn_addr)
        gregs[unsafe_offset=REG_RSP] = Int64(sp)
        gregs[unsafe_offset=REG_RDI] = Int64(arg_addr)

    def raw_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        """Return the raw buffer pointer, needed for swapcontext calls.

        Returns:
            The underlying ucontext_t buffer pointer.
        """
        return self._buf


# ── _UcontextStack ─────────────────────────────────────────────────────


struct _UcontextStack(Movable):
    """Complete platform backend for a single coroutine.

    Combines a guard-page-protected stack region with two ucontext_t buffers
    (one for the caller, one for the coroutine). Provides setup_entry for
    initial configuration and swap_to_coro/swap_to_caller for context switching.

    All platform-specific unsafe operations are encapsulated here. Higher-level
    coroutine types (Coroutine, StackPool) delegate to this struct for
    stack and context management.

    RAII: all three owned resources (_region, _caller_ctx, _coro_ctx) are
    auto-destructed when this struct is destroyed.
    """

    var _region: _MappedRegion
    var _caller_ctx: _UContext
    var _coro_ctx: _UContext
    var _pool_ref: Pointer[NoneType, MutUntrackedOrigin]

    def __init__(out self, stack_size: UInt) raises:
        """Allocate a coroutine stack and two ucontext buffers.

        Args:
            stack_size: Size of the usable stack in bytes.

        Raises:
            If mmap or mprotect fails during stack allocation.
        """
        self._region = _MappedRegion(stack_size)
        self._caller_ctx = _UContext()
        self._coro_ctx = _UContext()
        self._pool_ref = null_ptr[NoneType, MutUntrackedOrigin]()

    def __init__(out self, *, deinit move: Self):
        """Move constructor. Transfers ownership of all resources."""
        self._region = move._region^
        self._caller_ctx = move._caller_ctx^
        self._coro_ctx = move._coro_ctx^
        self._pool_ref = move._pool_ref

    def setup_entry(mut self, fn_addr: Int, arg_addr: Int) raises:
        """Configure the coroutine context for first execution.

        Calls getcontext to initialize the ucontext_t struct, then overwrites
        the stack and register fields so that swapcontext will jump to the
        entry function with arg_addr as its first argument register.

        Args:
            fn_addr: Address of the coroutine entry function.
            arg_addr: First argument (typically a pointer to shared state).

        Raises:
            If getcontext fails.
        """
        var page_size = get_page_size()
        self._coro_ctx.getcontext()
        self._coro_ctx.set_stack(
            self._region.usable_base(page_size),
            self._region.usable_size(page_size),
        )
        self._coro_ctx.set_entry(fn_addr, arg_addr)

    def swap_to_coro(mut self) raises:
        """Save the caller context and switch to the coroutine.

        Execution continues at the coroutine's entry point (first call)
        or where it last yielded (subsequent calls).

        Returns when the coroutine yields or completes.

        Raises:
            If swapcontext fails.
        """
        uc_swapcontext(self._caller_ctx.raw_ptr(), self._coro_ctx.raw_ptr())

    def swap_to_caller(mut self):
        """Save the coroutine context and switch back to the caller.

        Non-raising variant used in the yield path where raising is not
        allowed. Uses debug_assert for failure detection.
        """
        uc_swapcontext_unchecked(
            self._coro_ctx.raw_ptr(), self._caller_ctx.raw_ptr()
        )

    def set_pool_ref(
        mut self, pool_ptr: Pointer[NoneType, MutUntrackedOrigin]
    ):
        """Store a back-reference to the owning pool.

        Args:
            pool_ptr: Pointer to the pool's inner state, or null if not pooled.
        """
        self._pool_ref = pool_ptr

    def pool_ref(self) -> Pointer[NoneType, MutUntrackedOrigin]:
        """Return the stored pool back-reference.

        Returns:
            The pool pointer, or null (address 0) if not set.
        """
        return self._pool_ref

    def has_pool_ref(self) -> Bool:
        """Check whether a pool back-reference has been set.

        Returns:
            True if the pool reference is non-null.
        """
        return Int(self._pool_ref) != 0
