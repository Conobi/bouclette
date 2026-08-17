"""Coroutine — caller-side stackful coroutine handle."""

from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc
from boucle.socle.linux.ucontext import (
    free_ucontext,
    uc_getcontext,
    uc_swapcontext,
    setup_context,
)
from boucle.socle.linux.mm import (
    mmap_anonymous,
    mprotect,
    get_page_size,
    MapFlags,
    ProtFlags,
)
from boucle.socle.linux.raw import syscall
from boucle.socle.linux.raw import __NR_munmap
from boucle.socle.ptr import null_ptr
from ._state import (
    CORO_CREATED,
    CORO_RUNNING,
    CORO_SUSPENDED,
    CORO_DONE,
    DEFAULT_STACK_SIZE,
)
from .yielder import _CoroInner, CoroutineBody, _coro_trampoline


# ── Coroutine ───────────────────────────────────────────────────────────


@explicit_destroy("must call destroy() to release coroutine resources")
struct Coroutine(Movable):
    """Stackful coroutine. Caller-side handle.

    Lifecycle: CREATED -> RUNNING <-> SUSPENDED -> DONE

    Create with a body function and optional user_data pointer.
    Call resume() to start or continue the coroutine.
    The body calls Yielder.yield_to_caller() to suspend.

    Linear type: callers must explicitly call destroy() when done.
    """

    var _inner: UnsafePointer[_CoroInner, MutUntrackedOrigin]

    def __init__(
        out self,
        body: CoroutineBody,
        user_data: UnsafePointer[NoneType, MutUntrackedOrigin] = null_ptr[NoneType, MutUntrackedOrigin](),
        stack_size: UInt = DEFAULT_STACK_SIZE,
    ) raises:
        """Allocate a coroutine with a guard-page-protected stack.

        Args:
            body: The coroutine body function.
            user_data: Optional user data pointer accessible via Yielder.
            stack_size: Usable stack size in bytes (default 64 KB).
        """
        # Overflow check: ensure guard page + stack_size won't wrap
        var page_size = get_page_size()
        if stack_size > UInt.MAX - page_size:
            raise "stack size overflow: too large for guard page allocation"

        # Allocate stack: guard page + usable
        var total = page_size + stack_size
        var stack_base = mmap_anonymous(
            len=total,
            prot=ProtFlags.READ | ProtFlags.WRITE,
            flags=MapFlags.PRIVATE | MapFlags.STACK,
        )
        try:
            mprotect(
                unsafe_ptr=stack_base,
                len=page_size,
                prot=ProtFlags.NONE,
            )
        except e:
            # mprotect failed — unmap the stack before propagating
            _ = syscall[__NR_munmap, Scalar[DType.int64]](stack_base, total)
            raise e^

        # Allocate and initialize inner state on heap
        self._inner = alloc[_CoroInner](1)
        self._inner.init_pointee_move(
            _CoroInner(body, user_data, stack_base, total)
        )

        # Set up the coroutine context
        var usable_stack = UnsafePointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(stack_base) + Int(page_size)
        )
        try:
            uc_getcontext(self._inner[].coro_ctx)

            # Get trampoline function address
            var trampoline_fn = _coro_trampoline
            var fn_addr = Int(
                UnsafePointer(to=trampoline_fn).bitcast[Int]()[]
            )

            setup_context(
                self._inner[].coro_ctx,
                stack_ptr=usable_stack,
                stack_size=stack_size,
                entry_addr=fn_addr,
                arg_addr=Int(self._inner),
            )
        except e:
            # Cleanup: destroy self explicitly (satisfies @explicit_destroy)
            self^.destroy()
            raise e^

    def __init__(out self, *, deinit take: Self):
        """Move constructor for Coroutine."""
        self._inner = take._inner

    def destroy(deinit self):
        """Explicitly release all coroutine resources.

        Must be called by the owner -- the compiler enforces this
        via @explicit_destroy.
        """
        debug_assert(
            self._inner[].phase == CORO_CREATED
            or self._inner[].phase == CORO_DONE,
            "destroying a coroutine that hasn't finished",
        )
        # Free ucontext buffers
        free_ucontext(self._inner[].caller_ctx)
        free_ucontext(self._inner[].coro_ctx)
        # Unmap stack (non-raising: call syscall directly)
        _ = syscall[__NR_munmap, Scalar[DType.int64]](
            self._inner[].stack_base,
            self._inner[].stack_total,
        )
        # Destroy inner (runs String destructor for error_msg)
        self._inner.destroy_pointee()
        self._inner.free()

    def resume(mut self) raises:
        """Resume (or start) the coroutine.

        Returns when the body yields or completes.
        Raises if the body raised an error.
        """
        debug_assert(
            self.can_resume(),
            "resume() called on non-resumable coroutine",
        )
        self._inner[].phase = CORO_RUNNING
        uc_swapcontext(
            self._inner[].caller_ctx, self._inner[].coro_ctx
        )
        # We're back -- check for error
        if self._inner[].has_error:
            self._inner[].has_error = False
            raise self._inner[].error_msg

    def is_done(self) -> Bool:
        """True if the coroutine body has returned or raised."""
        return self._inner[].phase == CORO_DONE

    def can_resume(self) -> Bool:
        """True if the coroutine can be resumed (CREATED or SUSPENDED)."""
        return (
            self._inner[].phase == CORO_CREATED
            or self._inner[].phase == CORO_SUSPENDED
        )

    def reset(
        mut self,
        body: CoroutineBody,
        user_data: UnsafePointer[NoneType, MutUntrackedOrigin] = null_ptr[NoneType, MutUntrackedOrigin](),
    ) raises:
        """Recycle this coroutine for a new body, reusing its stack and
        ucontext storage. Caller must ensure the coro is CREATED or DONE
        (i.e. not currently suspended or running). After reset, the coro
        is in CREATED — call resume() to start the new body.

        Used by `CoroutinePool` to amortise the per-request stack mmap
        + setup_context cost across many request lifetimes.
        """
        debug_assert(
            self._inner[].phase == CORO_CREATED
            or self._inner[].phase == CORO_DONE,
            "reset() called on a running or suspended coroutine",
        )
        self._inner[].body = body
        self._inner[].user_data = user_data
        self._inner[].has_error = False
        self._inner[].error_msg = String()
        self._inner[].phase = CORO_CREATED

        var page_size = get_page_size()
        var stack_total = self._inner[].stack_total
        debug_assert(stack_total >= page_size, "corrupted stack_total")
        var stack_size = stack_total - page_size
        var usable_stack = UnsafePointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(self._inner[].stack_base) + Int(page_size)
        )
        uc_getcontext(self._inner[].coro_ctx)
        var trampoline_fn = _coro_trampoline
        var fn_addr = Int(
            UnsafePointer(to=trampoline_fn).bitcast[Int]()[]
        )
        setup_context(
            self._inner[].coro_ctx,
            stack_ptr=usable_stack,
            stack_size=stack_size,
            entry_addr=fn_addr,
            arg_addr=Int(self._inner),
        )
