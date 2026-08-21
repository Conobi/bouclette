"""StackPool — free-list pool reusing coroutine stacks.

Heap-boxes the pool state into _PoolInner so that moving a StackPool
copies the pointer, keeping back-references from _CoroStack objects
valid across moves.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from boucle.socle.ptr import null_ptr
from ._state import DEFAULT_STACK_SIZE
from ._stack import _CoroStack


# ── _PoolInner ─────────────────────────────────────────────────────────


struct _PoolInner:
    """Heap-allocated pool state for address stability.

    Holds the free list, stack size configuration, and capacity limit.
    Never moved — StackPool holds a pointer to this.
    """

    var free: List[Pointer[_CoroStack, MutUntrackedOrigin]]
    var stack_size: UInt
    var capacity: Int

    def __init__(
        out self,
        *,
        capacity: Int,
        stack_size: UInt,
    ):
        """Initialize pool inner state.

        Args:
            capacity: Maximum number of idle stacks to cache.
            stack_size: Size of each usable stack in bytes.
        """
        self.free = List[Pointer[_CoroStack, MutUntrackedOrigin]]()
        self.stack_size = stack_size
        self.capacity = capacity


# ── StackPool ──────────────────────────────────────────────────────────


struct StackPool(Movable):
    """Free-list pool of coroutine stacks backed by _CoroStack.

    Reuses mmap'd, guard-page-protected stacks across coroutine lifetimes,
    amortising the per-spawn mmap + mprotect cost.

    The pool keeps up to `capacity` idle stacks. `_acquire_stack()` returns
    an idle stack or allocates a fresh one. `_release_stack()` puts the
    stack back on the free list, or destroys it if the cap is exceeded.

    Implementation detail: the pool state lives in a heap-allocated
    _PoolInner. Moving a StackPool copies the pointer, so back-references
    from _CoroStack objects (via set_pool_ref) stay valid.

    Per-thread safety: the pool itself is not thread-safe. In a worker
    model where one thread owns one loop, give that thread its own pool.
    """

    var _inner: Pointer[_PoolInner, MutUntrackedOrigin]

    def __init__(
        out self,
        *,
        capacity: Int = 256,
        stack_size: UInt = DEFAULT_STACK_SIZE,
    ):
        """Initialize the pool with a maximum idle capacity and stack size.

        Args:
            capacity: Maximum number of idle stacks to cache.
            stack_size: Size of each usable stack in bytes (default 64 KB).
        """
        self._inner = unsafe_alloc[_PoolInner](1)
        self._inner.unsafe_write(
            _PoolInner(capacity=capacity, stack_size=stack_size)
        )

    def __init__(out self, *, deinit move: Self):
        """Move constructor. Copies the inner pointer for address stability."""
        self._inner = move._inner

    def __deinit__(deinit self):
        """Destroy all idle stacks and free the inner state."""
        for i in range(len(self._inner[].free)):
            var ptr = self._inner[].free[i]
            # Take the _CoroStack out, letting its destructor unmap the region
            _ = ptr.unsafe_take_pointee()
            ptr.unsafe_free()
        self._inner.unsafe_deinit_pointee()
        self._inner.unsafe_free()

    def idle_count(self) -> Int:
        """Number of idle stacks currently parked in the pool.

        Returns:
            The number of stacks available for reuse.
        """
        return len(self._inner[].free)

    def _acquire_stack(mut self) raises -> Pointer[_CoroStack, MutUntrackedOrigin]:
        """Return a stack ready for use, from the free list or freshly allocated.

        Pops from the free list (fast path) or allocates a new _CoroStack
        (slow path). Sets the pool back-reference on the returned stack.

        Returns:
            A pointer to a _CoroStack with its pool back-reference set.

        Raises:
            If mmap or mprotect fails during fresh stack allocation.
        """
        var ptr: Pointer[_CoroStack, MutUntrackedOrigin]
        if len(self._inner[].free) > 0:
            ptr = self._inner[].free.pop()
        else:
            ptr = unsafe_alloc[_CoroStack](1)
            ptr.unsafe_write(_CoroStack(self._inner[].stack_size))
        # Set pool back-reference so the stack can find its way home
        ptr[].set_pool_ref(
            Pointer[NoneType, MutUntrackedOrigin](
                unsafe_from_address=Int(self._inner)
            )
        )
        return ptr

    def _release_stack(
        mut self, ptr: Pointer[_CoroStack, MutUntrackedOrigin]
    ):
        """Return a stack to the pool, or destroy it if over capacity.

        If the free list is under capacity, the stack is cached for reuse.
        Otherwise, the stack is destroyed (unmapping its memory region).

        Args:
            ptr: Pointer to the _CoroStack to release.
        """
        if len(self._inner[].free) < self._inner[].capacity:
            self._inner[].free.append(ptr)
        else:
            # Over capacity — destroy the stack
            _ = ptr.unsafe_take_pointee()
            ptr.unsafe_free()
