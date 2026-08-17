"""Yielder, internal shared state, and trampoline for stackful coroutines.

Contains the tightly-coupled types that cannot be split across modules:
_CoroInner references CoroutineBody (which names Yielder in its signature),
and Yielder references _CoroInner via UnsafePointer.
"""

from std.os import abort
from std.memory import UnsafePointer
from boucle.socle.linux.ucontext import (
    alloc_ucontext,
    uc_swapcontext_unchecked,
)
from boucle.socle.linux.raw.ctypes import c_void
from ._state import (
    CORO_MAGIC,
    CORO_CREATED,
    CORO_RUNNING,
    CORO_SUSPENDED,
    CORO_DONE,
)


# Body function type: receives a mutable Yielder, may raise
comptime CoroutineBody = def (mut Yielder) thin raises -> None


# ── Yielder ─────────────────────────────────────────────────────────────


struct Yielder:
    """Coroutine-side handle. Passed to the body function.

    Only valid inside the coroutine body -- do not store or
    use after the body returns.
    """

    var _inner: UnsafePointer[_CoroInner, MutUntrackedOrigin]

    def __init__(out self, inner: UnsafePointer[_CoroInner, MutUntrackedOrigin]):
        """Initialize with a pointer to the shared coroutine state."""
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
        """Access the user data pointer passed at Coroutine creation."""
        return self._inner[].user_data


# ── _CoroInner ──────────────────────────────────────────────────────────


struct _CoroInner(Movable):
    """Heap-allocated shared state between Coroutine and Yielder.

    Stable address -- survives Coroutine moves.
    """

    var magic: UInt64
    var caller_ctx: UnsafePointer[UInt8, MutUntrackedOrigin]
    var coro_ctx: UnsafePointer[UInt8, MutUntrackedOrigin]
    var stack_base: UnsafePointer[c_void, StaticConstantOrigin]
    var stack_total: UInt
    var phase: UInt8
    var body: CoroutineBody
    var user_data: UnsafePointer[NoneType, MutUntrackedOrigin]
    var has_error: Bool
    var error_msg: String

    def __init__(
        out self,
        body: CoroutineBody,
        user_data: UnsafePointer[NoneType, MutUntrackedOrigin],
        stack_base: UnsafePointer[c_void, StaticConstantOrigin],
        stack_total: UInt,
    ):
        """Initialize shared coroutine state with allocated ucontext buffers."""
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
        """Move constructor for _CoroInner."""
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


# ── Trampoline ──────────────────────────────────────────────────────────


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
    var yielder = Yielder(inner)
    try:
        inner[].body(yielder)
    except e:
        inner[].has_error = True
        inner[].error_msg = String(e)
    inner[].phase = CORO_DONE
    uc_swapcontext_unchecked(inner[].coro_ctx, inner[].caller_ctx)
    # Unreachable -- if we get here, the coroutine stack is corrupt.
    # The process will likely crash on the next instruction.
