"""CoroutinePool — free-list pool reusing coroutine stacks."""

from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc
from boucle.socle.ptr import null_ptr
from ._state import DEFAULT_STACK_SIZE
from .handle import Coroutine
from .yielder import CoroutineBody


# ── CoroutinePool ───────────────────────────────────────────────────────


struct CoroutinePool(Movable):
    """A free-list of `Coroutine` instances. Reuses stacks + ucontexts
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

    var _free: List[UnsafePointer[Coroutine, MutAnyOrigin]]
    var _stack_size: UInt
    var _capacity: Int

    def __init__(
        out self,
        *,
        capacity: Int = 256,
        stack_size: UInt = DEFAULT_STACK_SIZE,
    ):
        """Initialize the pool with a maximum idle capacity and stack size."""
        self._free = List[UnsafePointer[Coroutine, MutAnyOrigin]]()
        self._stack_size = stack_size
        self._capacity = capacity

    def __init__(out self, *, deinit take: Self):
        """Move constructor for CoroutinePool."""
        self._free = take._free^
        self._stack_size = take._stack_size
        self._capacity = take._capacity

    def __del__(deinit self):
        """Destroy all idle coroutines in the pool."""
        for i in range(len(self._free)):
            var ptr = self._free[i]
            ptr.take_pointee().destroy()
            ptr.free()

    def acquire(
        mut self,
        body: CoroutineBody,
        user_data: UnsafePointer[NoneType, MutUntrackedOrigin] = null_ptr[NoneType, MutUntrackedOrigin](),
    ) raises -> UnsafePointer[Coroutine, MutAnyOrigin]:
        """Return a `Coroutine` ready to run `body`. Either pops from
        the free list (fast path, just `reset`) or allocates fresh
        (slow path, full `__init__`).
        """
        if len(self._free) > 0:
            var ptr = self._free.pop()
            ptr[].reset(body, user_data)
            return ptr
        var ptr = alloc[Coroutine](1).as_unsafe_any_origin()
        var h = Coroutine(body, user_data, self._stack_size)
        ptr.init_pointee_move(h^)
        return ptr

    def release(mut self, ptr: UnsafePointer[Coroutine, MutAnyOrigin]):
        """Return a (DONE) `Coroutine` to the pool. Beyond `capacity`
        idle handles, the surplus is destroyed instead of cached.
        """
        if len(self._free) >= self._capacity:
            ptr.take_pointee().destroy()
            ptr.free()
            return
        self._free.append(ptr)

    def idle_count(self) -> Int:
        """Number of idle handles currently parked in the pool."""
        return len(self._free)
