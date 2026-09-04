"""Coroutine — caller-side typed stackful coroutine handle."""

from std.os import abort
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from ._state import Phase, DEFAULT_STACK_SIZE
from ._stack import _CoroStack
from .yielder import _CoroInner, CoroutineBody, _coro_entry
from .pool import StackPool, _release_to_pool


# ── Coroutine ───────────────────────────────────────────────────────────


@explicit_destroy("must call close() to release coroutine resources")
struct Coroutine[State: Movable & Deinitable](Movable, Deinitable where False):
    """Typed stackful coroutine. Caller-side handle.

    Lifecycle: CREATED -> RUNNING <-> SUSPENDED -> DONE

    Parametric on State — the typed shared state accessible to both
    the caller (via state()) and the body (via Yielder.state()).

    Create with a body function and an initial state value.
    Call resume() to start or continue the coroutine.
    The body calls Yielder.suspend() to yield.

    Linear type: callers must explicitly call close() when done.
    """

    var _inner: Pointer[_CoroInner[Self.State], MutUntrackedOrigin]

    def __init__(
        out self,
        body: CoroutineBody[Self.State],
        var state: Self.State,
        stack_size: UInt = DEFAULT_STACK_SIZE,
    ) raises:
        """Allocate a coroutine with a freshly mmap'd stack.

        Args:
            body: The coroutine body function.
            state: The typed shared state (ownership transferred in).
            stack_size: Usable stack size in bytes (default 64 KB).

        Raises:
            If stack allocation or context setup fails.
        """
        # Allocate the platform stack backend on the heap
        var stack_ptr = unsafe_alloc[_CoroStack](1)
        try:
            stack_ptr.unsafe_write(_CoroStack(stack_size))
        except e:
            stack_ptr.unsafe_free()
            raise e^

        # Allocate and initialize shared coroutine state on the heap
        self._inner = unsafe_alloc[_CoroInner[Self.State]](1)
        self._inner.unsafe_write(
            _CoroInner[Self.State](body, stack_ptr, state^)
        )

        # Extract monomorphized entry function address and configure context
        var entry_fn = _coro_entry[Self.State]
        var fn_addr = Int(Pointer(to=entry_fn).unsafe_bitcast[Int]()[])
        try:
            stack_ptr[].setup_entry(fn_addr, Int(self._inner))
        except e:
            self^.close()
            raise e^

    def __init__(
        out self,
        body: CoroutineBody[Self.State],
        var state: Self.State,
        mut pool: StackPool,
    ) raises:
        """Allocate a coroutine using a pooled stack.

        Args:
            body: The coroutine body function.
            state: The typed shared state (ownership transferred in).
            pool: Stack pool to acquire the stack from.

        Raises:
            If stack acquisition or context setup fails.
        """
        var stack_ptr = pool._acquire_stack()

        # Allocate and initialize shared coroutine state on the heap
        self._inner = unsafe_alloc[_CoroInner[Self.State]](1)
        self._inner.unsafe_write(
            _CoroInner[Self.State](body, stack_ptr, state^)
        )

        # Extract monomorphized entry function address and configure context
        var entry_fn = _coro_entry[Self.State]
        var fn_addr = Int(Pointer(to=entry_fn).unsafe_bitcast[Int]()[])
        try:
            stack_ptr[].setup_entry(fn_addr, Int(self._inner))
        except e:
            self^.close()
            raise e^

    def __init__(out self, *, deinit move: Self):
        """Move constructor for Coroutine. Transfers the inner pointer."""
        self._inner = move._inner

    def resume(mut self) raises:
        """Resume (or start) the coroutine.

        Returns when the body yields or completes.

        Raises:
            If the body raised an error during execution.
        """
        debug_assert(
            self.can_resume(),
            "resume() called on non-resumable coroutine",
        )
        self._inner[].phase = Phase.RUNNING
        self._inner[].stack[].swap_to_coro()
        # Back here — check for error propagated from body
        if self._inner[].has_error:
            self._inner[].has_error = False
            raise self._inner[].error_msg

    def is_done(self) -> Bool:
        """True if the coroutine body has returned or raised."""
        return self._inner[].phase == Phase.DONE

    def can_resume(self) -> Bool:
        """True if the coroutine can be resumed (CREATED or SUSPENDED)."""
        return (
            self._inner[].phase == Phase.CREATED
            or self._inner[].phase == Phase.SUSPENDED
        )

    def state(self) -> Pointer[Self.State, MutUntrackedOrigin]:
        """Access the typed shared state owned by _CoroInner.

        Returns:
            A mutable untracked pointer to the State value.
        """
        return Pointer[Self.State, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._inner[].state))
        )

    def cancel(mut self):
        """Request cancellation and drain the coroutine to DONE.

        Sets the cancelled flag and resumes the coroutine repeatedly
        until it reaches DONE. Swallows any errors from the body.
        Safe to call on a coroutine that is already DONE.

        Aborts the process if context switching fails, which indicates
        unrecoverable corruption of the coroutine state.
        """
        if self.is_done():
            return
        self._inner[].cancelled = True
        var iterations = 0
        while not self.is_done():
            debug_assert(
                iterations < 1000,
                "cancel() exceeded 1000 iterations",
            )
            self._inner[].phase = Phase.RUNNING
            try:
                self._inner[].stack[].swap_to_coro()
            except e:
                abort(
                    "cancel: swap_to_coro failed - coroutine state is corrupt"
                )
            # Swallow any error from the body
            if self._inner[].has_error:
                self._inner[].has_error = False
                self._inner[].error_msg = String()
            iterations += 1

    def close(deinit self):
        """Explicitly release all coroutine resources.

        Must be called by the owner — the compiler enforces this
        via @explicit_destroy.

        The coroutine must be in CREATED or DONE state. If the stack
        was acquired from a StackPool, it is returned to the pool.
        Otherwise, the stack is destroyed (unmapping its memory region).
        """
        debug_assert(
            self._inner[].phase == Phase.CREATED
            or self._inner[].phase == Phase.DONE,
            "close() on RUNNING or SUSPENDED coroutine",
        )
        var stack_ptr = self._inner[].stack
        var pool_ref = stack_ptr[].pool_ref()

        # Free _CoroInner (runs destructors for state and error_msg)
        self._inner.unsafe_deinit_pointee()
        self._inner.unsafe_free()

        # Return stack to pool or destroy it
        if Int(pool_ref) != 0:
            _release_to_pool(pool_ref, stack_ptr)
        else:
            _ = stack_ptr.unsafe_take_pointee()
            stack_ptr.unsafe_free()
