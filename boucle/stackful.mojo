"""Stackful coroutines via ucontext FFI.

Provides CoroHandle (caller-side) and CoroYielder (coroutine-side)
for cooperative multitasking with real yield/resume semantics.

Linux x86_64 only. Uses POSIX ucontext_t via external_call.
Bridge until Modular ships native waker APIs.
"""

from std.os import abort
from std.memory import UnsafePointer, memset
from std.memory.unsafe_pointer import alloc
from boucle.socle.linux.ucontext import (
    alloc_ucontext,
    free_ucontext,
    uc_getcontext,
    uc_swapcontext,
    uc_swapcontext_unchecked,
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
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.ptr import null_ptr


# Phase constants
comptime CORO_CREATED: UInt8 = 0
comptime CORO_RUNNING: UInt8 = 1
comptime CORO_SUSPENDED: UInt8 = 2
comptime CORO_DONE: UInt8 = 3

# Default stack size (64 KB usable)
comptime DEFAULT_STACK_SIZE: UInt = 65536

# Magic canary for _CoroInner integrity validation
comptime CORO_MAGIC: UInt64 = 0xC0C0_CAFE_B0C1_E000

# Body function type: receives a mutable CoroYielder, may raise
comptime CoroBody = def (mut CoroYielder) thin raises -> None


# ── CoroYielder ──────────────────────────────────────────────────────────


struct CoroYielder:
    """Coroutine-side handle. Passed to the body function.

    Only valid inside the coroutine body -- do not store or
    use after the body returns.
    """

    var _inner: UnsafePointer[_CoroInner, MutUntrackedOrigin]

    def __init__(out self, inner: UnsafePointer[_CoroInner, MutUntrackedOrigin]):
        self._inner = inner

    def yield_to_caller(mut self):
        """Suspend this coroutine and return control to the caller.

        Execution resumes from here when the caller calls resume().
        """
        self._inner[].phase = CORO_SUSPENDED
        # Unchecked: yield can't raise (no way to propagate from here),
        # and swapcontext only fails with invalid pointers — which would
        # mean _CoroInner is already corrupt. Checking would add overhead
        # on every yield for a condition that indicates unrecoverable state.
        uc_swapcontext_unchecked(
            self._inner[].coro_ctx, self._inner[].caller_ctx
        )
        # When we return here, the caller called resume() again
        self._inner[].phase = CORO_RUNNING

    def user_data(self) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
        """Access the user data pointer passed at CoroHandle creation."""
        return self._inner[].user_data


# ── _CoroInner ───────────────────────────────────────────────────────────


struct _CoroInner(Movable):
    """Heap-allocated shared state between CoroHandle and CoroYielder.

    Stable address -- survives CoroHandle moves.
    """

    var magic: UInt64
    var caller_ctx: UnsafePointer[UInt8, MutUntrackedOrigin]
    var coro_ctx: UnsafePointer[UInt8, MutUntrackedOrigin]
    var stack_base: UnsafePointer[c_void, StaticConstantOrigin]
    var stack_total: UInt
    var phase: UInt8
    var body: CoroBody
    var user_data: UnsafePointer[NoneType, MutUntrackedOrigin]
    var has_error: Bool
    var error_msg: String

    def __init__(
        out self,
        body: CoroBody,
        user_data: UnsafePointer[NoneType, MutUntrackedOrigin],
        stack_base: UnsafePointer[c_void, StaticConstantOrigin],
        stack_total: UInt,
    ):
        self.magic = CORO_MAGIC
        self.caller_ctx = alloc_ucontext()
        self.coro_ctx = alloc_ucontext()
        self.stack_base = stack_base
        self.stack_total = stack_total
        self.phase = CORO_CREATED
        self.body = body
        self.user_data = user_data
        self.has_error = False
        self.error_msg = String()

    def __init__(out self, *, deinit take: Self):
        self.magic = take.magic
        self.caller_ctx = take.caller_ctx
        self.coro_ctx = take.coro_ctx
        self.stack_base = take.stack_base
        self.stack_total = take.stack_total
        self.phase = take.phase
        self.body = take.body
        self.user_data = take.user_data
        self.has_error = take.has_error
        self.error_msg = take.error_msg^


# ── Trampoline ───────────────────────────────────────────────────────────


def _coro_trampoline(inner_addr: Int64):
    """Entry point for new coroutines. Runs on the coroutine stack.

    Receives a pointer to _CoroInner via REG_RDI.
    Calls the user's body function, catches errors, marks DONE, swaps back.
    MUST never return normally -- always swaps back to caller.
    """
    var inner = UnsafePointer[_CoroInner, MutUntrackedOrigin](
        unsafe_from_address=Int(inner_addr)
    )
    # Always-on canary: a corrupt pointer here means unrecoverable state.
    if inner[].magic != CORO_MAGIC:
        abort("corrupted _CoroInner: bad magic number")
    var yielder = CoroYielder(inner)
    try:
        inner[].body(yielder)
    except e:
        inner[].has_error = True
        inner[].error_msg = String(e)
    inner[].phase = CORO_DONE
    uc_swapcontext_unchecked(inner[].coro_ctx, inner[].caller_ctx)
    # Unreachable -- if we get here, the coroutine stack is corrupt.
    # The process will likely crash on the next instruction.


# ── CoroHandle ───────────────────────────────────────────────────────────


@explicit_destroy("must call destroy() to release coroutine resources")
struct CoroHandle(Movable):
    """Stackful coroutine. Caller-side handle.

    Lifecycle: CREATED -> RUNNING <-> SUSPENDED -> DONE

    Create with a body function and optional user_data pointer.
    Call resume() to start or continue the coroutine.
    The body calls CoroYielder.yield_to_caller() to suspend.

    Linear type: callers must explicitly call destroy() when done.
    """

    var _inner: UnsafePointer[_CoroInner, MutUntrackedOrigin]

    def __init__(
        out self,
        body: CoroBody,
        user_data: UnsafePointer[NoneType, MutUntrackedOrigin] = null_ptr[NoneType, MutUntrackedOrigin](),
        stack_size: UInt = DEFAULT_STACK_SIZE,
    ) raises:
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
        body: CoroBody,
        user_data: UnsafePointer[NoneType, MutUntrackedOrigin] = null_ptr[NoneType, MutUntrackedOrigin](),
    ) raises:
        """Recycle this coroutine for a new body, reusing its stack and
        ucontext storage. Caller must ensure the coro is CREATED or DONE
        (i.e. not currently suspended or running). After reset, the coro
        is in CREATED — call resume() to start the new body.

        Used by `CoroutinePool` to amortise the per-request stack mmap
        + setup_context cost across many request lifetimes."""
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


# ── CoroutinePool ────────────────────────────────────────────────────────


struct CoroutinePool(Movable):
    """A free-list of `CoroHandle` instances. Reuses stacks + ucontexts
    across multiple body executions, amortising the per-spawn mmap +
    `getcontext` + `setup_context` cost.

    The pool keeps up to `capacity` idle handles. `acquire()` returns an
    idle handle reset for a new body, or allocates fresh if the free
    list is empty. `release()` puts the handle back on the free list,
    or destroys it if the cap is exceeded.

    Per-thread safety: the pool itself is not thread-safe. In a worker
    model where one thread owns one CompletionLoop, give that thread its
    own pool.
    """

    var _free: List[UnsafePointer[CoroHandle, MutAnyOrigin]]
    var _stack_size: UInt
    var _capacity: Int

    def __init__(
        out self,
        *,
        capacity: Int = 256,
        stack_size: UInt = DEFAULT_STACK_SIZE,
    ):
        self._free = List[UnsafePointer[CoroHandle, MutAnyOrigin]]()
        self._stack_size = stack_size
        self._capacity = capacity

    def __init__(out self, *, deinit take: Self):
        self._free = take._free^
        self._stack_size = take._stack_size
        self._capacity = take._capacity

    def __del__(deinit self):
        for i in range(len(self._free)):
            var ptr = self._free[i]
            ptr.take_pointee().destroy()
            ptr.free()

    def acquire(
        mut self,
        body: CoroBody,
        user_data: UnsafePointer[NoneType, MutUntrackedOrigin] = null_ptr[NoneType, MutUntrackedOrigin](),
    ) raises -> UnsafePointer[CoroHandle, MutAnyOrigin]:
        """Return a `CoroHandle` ready to run `body`. Either pops from
        the free list (fast path, just `reset`) or allocates fresh
        (slow path, full `__init__`)."""
        if len(self._free) > 0:
            var ptr = self._free.pop()
            ptr[].reset(body, user_data)
            return ptr
        var ptr = alloc[CoroHandle](1).as_unsafe_any_origin()
        var h = CoroHandle(body, user_data, self._stack_size)
        ptr.init_pointee_move(h^)
        return ptr

    def release(mut self, ptr: UnsafePointer[CoroHandle, MutAnyOrigin]):
        """Return a (DONE) `CoroHandle` to the pool. Beyond `capacity`
        idle handles, the surplus is destroyed instead of cached."""
        if len(self._free) >= self._capacity:
            ptr.take_pointee().destroy()
            ptr.free()
            return
        self._free.append(ptr)

    def idle_count(self) -> Int:
        """Number of idle handles currently parked in the pool."""
        return len(self._free)
