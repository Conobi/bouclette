"""Yielder, internal shared state, and entry point for stackful coroutines.

Contains the tightly-coupled types that cannot be split across modules:
_CoroInner[State] references CoroutineBody[State] (which names Yielder[State]
in its signature), and Yielder[State] references _CoroInner[State] via Pointer.

All types are parametric on State: Movable & Deinitable — the typed shared
state that replaces the old untyped user_data pointer.
"""

from std.os import abort
from std.memory import Pointer
from ._state import CORO_MAGIC, Phase
from ._stack import _CoroStack


# Body function type: receives a mutable Yielder[State], may raise
comptime CoroutineBody[State: Movable & Deinitable] = def (
    mut Yielder[State]
) thin raises -> None


# ── Yielder ─────────────────────────────────────────────────────────────


struct Yielder[State: Movable & Deinitable]:
    """Coroutine-side handle. Passed to the body function.

    Parametric on State — the typed shared state accessible via state().
    Only valid inside the coroutine body — do not store or
    use after the body returns.
    """

    var _inner: Pointer[_CoroInner[Self.State], MutUntrackedOrigin]

    def __init__(
        out self,
        inner: Pointer[_CoroInner[Self.State], MutUntrackedOrigin],
    ):
        """Initialize with a pointer to the shared coroutine state.

        Args:
            inner: Pointer to the _CoroInner that owns this coroutine's state.
        """
        self._inner = inner

    def suspend(mut self):
        """Suspend this coroutine and return control to the caller.

        Sets the phase to SUSPENDED, swaps to the caller context via the
        platform stack backend, and restores RUNNING when resumed.
        Execution resumes from here when the caller calls resume().
        """
        self._inner[].phase = Phase.SUSPENDED
        # swap_to_caller is non-raising: yield can't propagate errors,
        # and swapcontext only fails with invalid pointers — which would
        # mean _CoroInner is already corrupt.
        self._inner[].stack[].swap_to_caller()
        # When we return here, the caller called resume() again
        self._inner[].phase = Phase.RUNNING

    def state(self) -> Pointer[Self.State, MutUntrackedOrigin]:
        """Access the typed shared state owned by _CoroInner.

        Returns:
            A mutable untracked pointer to the State value stored in _CoroInner.
        """
        return Pointer[Self.State, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._inner[].state))
        )

    def is_cancelled(self) -> Bool:
        """Check whether cancellation has been requested by the caller.

        Returns:
            True if the caller has set the cancelled flag.
        """
        return self._inner[].cancelled


# ── _CoroInner ──────────────────────────────────────────────────────────


struct _CoroInner[State: Movable & Deinitable](Movable):
    """Heap-allocated shared state between Coroutine and Yielder.

    Parametric on State — replaces the old untyped user_data pointer with
    a typed state value owned directly by this struct.

    Stable address — survives Coroutine moves.
    """

    var magic: UInt64
    var stack: Pointer[_CoroStack, MutUntrackedOrigin]
    var phase: Phase
    var body: CoroutineBody[Self.State]
    var state: Self.State
    var cancelled: Bool
    var has_error: Bool
    var error_msg: String

    def __init__(
        out self,
        body: CoroutineBody[Self.State],
        stack_ptr: Pointer[_CoroStack, MutUntrackedOrigin],
        var state: Self.State,
    ):
        """Initialize shared coroutine state with a typed body and state.

        Args:
            body: The coroutine body function (typed for this State).
            stack_ptr: Pointer to the platform stack backend.
            state: The typed shared state value (ownership transferred in).
        """
        self.magic = CORO_MAGIC
        self.stack = stack_ptr
        self.phase = Phase.CREATED
        self.body = body
        self.state = state^
        self.cancelled = False
        self.has_error = False
        self.error_msg = String()

    def __init__(out self, *, deinit move: Self):
        """Move constructor for _CoroInner. Transfers all fields."""
        self.magic = move.magic
        self.stack = move.stack
        self.phase = move.phase
        self.body = move.body
        self.state = move.state^
        self.cancelled = move.cancelled
        self.has_error = move.has_error
        self.error_msg = move.error_msg^


# ── Coroutine entry point ───────────────────────────────────────────────


def _coro_entry[State: Movable & Deinitable](inner_addr: Int64):
    """Monomorphized entry point — one concrete function per State type.

    Runs on the coroutine stack. Receives a pointer to _CoroInner[State]
    via REG_RDI. Calls the user's body function, catches errors,
    marks DONE, and swaps back to the caller.
    MUST never return normally — always swaps back to caller.

    Args:
        inner_addr: Address of the _CoroInner[State] on the heap.
    """
    var inner = Pointer[_CoroInner[State], MutUntrackedOrigin](
        unsafe_from_address=Int(inner_addr)
    )
    # Debug-only canary: validates pointer reconstruction at the ucontext boundary.
    debug_assert(inner[].magic == CORO_MAGIC, "corrupted _CoroInner")
    var yielder = Yielder[State](inner)
    try:
        inner[].body(yielder)
    except e:
        inner[].has_error = True
        inner[].error_msg = String(e)
    inner[].phase = Phase.DONE
    inner[].stack[].swap_to_caller()
    # Unreachable — if we get here, the coroutine stack is corrupt.
    # The process will likely crash on the next instruction.
