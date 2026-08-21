"""Tests for _UcontextStack RAII platform backend.

Validates that _MappedRegion, _UContext, and _UcontextStack correctly
encapsulate the mmap + ucontext lifecycle:
- Stack allocation with guard page
- Context setup and register configuration
- Round-trip context switch (swap_to_coro + swap_to_caller)
- Multi-swap ping-pong
- Pool back-reference storage
"""

from boucle._sys.linux.ucontext_stack import (
    _MappedRegion,
    _UContext,
    _UcontextStack,
)
from boucle.socle.linux.mm import get_page_size
from boucle.socle.ptr import null_ptr
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true


comptime STACK_SIZE: UInt = 65536  # 64 KB usable stack


# ── Entry points ───────────────────────────────────────────────────────
#
# These run on the coroutine stack via swapcontext. They receive a raw
# integer address pointing to packed args: [stack_addr, shared_addr].
# They call swap_to_caller on the _UcontextStack to yield back.


def _entry_write42(arg_raw: Int64):
    """Write 42 to shared memory and swap back to caller.

    arg_raw -> Int[2]: [stack_addr, shared_addr].
    """
    var args = Pointer[Int, MutUntrackedOrigin](
        unsafe_from_address=Int(arg_raw)
    )
    var stack = Pointer[_UcontextStack, MutUntrackedOrigin](
        unsafe_from_address=args[unsafe_offset=0]
    )
    var shared = Pointer[Int, MutUntrackedOrigin](
        unsafe_from_address=args[unsafe_offset=1]
    )
    shared[] = 42
    stack[].swap_to_caller()


def _entry_pingpong(arg_raw: Int64):
    """Increment a shared counter 3 times, yielding between each.

    arg_raw -> Int[2]: [stack_addr, counter_addr].
    """
    var args = Pointer[Int, MutUntrackedOrigin](
        unsafe_from_address=Int(arg_raw)
    )
    var stack = Pointer[_UcontextStack, MutUntrackedOrigin](
        unsafe_from_address=args[unsafe_offset=0]
    )
    var counter = Pointer[Int, MutUntrackedOrigin](
        unsafe_from_address=args[unsafe_offset=1]
    )

    # Round 1
    counter[] = counter[] + 1
    stack[].swap_to_caller()

    # Round 2
    counter[] = counter[] + 1
    stack[].swap_to_caller()

    # Round 3
    counter[] = counter[] + 1
    stack[].swap_to_caller()


# ── Tests ──────────────────────────────────────────────────────────────


def test_mapped_region_lifecycle() raises:
    """_MappedRegion allocates and protects a stack region without crashing."""
    var region = _MappedRegion(STACK_SIZE)
    var page_size = get_page_size()

    # Usable base is past the guard page
    var base_addr = Int(region.usable_base(page_size))
    var region_addr = Int(region._base)
    assert_equal(base_addr, region_addr + Int(page_size))

    # Usable size is total minus guard page
    assert_equal(region.usable_size(page_size), STACK_SIZE)
    # region auto-destructs (munmap) when it goes out of scope


def test_ucontext_lifecycle() raises:
    """_UContext allocates, initializes, and frees a ucontext_t buffer."""
    var ctx = _UContext()
    ctx.getcontext()
    # Reaching here without crash proves alloc + getcontext work
    var ptr = ctx.raw_ptr()
    assert_true(Int(ptr) != 0, "ucontext buffer must be non-null")
    # ctx auto-destructs (free_ucontext) when it goes out of scope


def test_round_trip() raises:
    """Single swap to entry point and back validates the full RAII round-trip.

    Proves that _UcontextStack.setup_entry + swap_to_coro correctly
    configures the stack, registers, and context switch.
    """
    var shared = unsafe_alloc[Int](1)
    shared[] = 0

    var stack = _UcontextStack(STACK_SIZE)

    # Pack entry args: [stack address, shared address]
    var args = unsafe_alloc[Int](2)
    args[unsafe_offset=0] = Int(Pointer(to=stack))
    args[unsafe_offset=1] = Int(shared)

    # Get entry function address
    var entry_fn = _entry_write42
    var fn_addr = Int(Pointer(to=entry_fn).unsafe_bitcast[Int]()[])

    stack.setup_entry(fn_addr, Int(args))
    stack.swap_to_coro()

    # Verify the entry point ran
    assert_equal(shared[], 42)

    # Cleanup (args/shared are manual allocs; stack is RAII)
    args.unsafe_free()
    shared.unsafe_free()


def test_pingpong() raises:
    """Multiple context switches validate save/restore reliability.

    The caller and coroutine swap back and forth 3 times, with the
    coroutine incrementing a shared counter at each step.
    """
    var counter = unsafe_alloc[Int](1)
    counter[] = 0

    var stack = _UcontextStack(STACK_SIZE)

    var args = unsafe_alloc[Int](2)
    args[unsafe_offset=0] = Int(Pointer(to=stack))
    args[unsafe_offset=1] = Int(counter)

    var entry_fn = _entry_pingpong
    var fn_addr = Int(Pointer(to=entry_fn).unsafe_bitcast[Int]()[])

    stack.setup_entry(fn_addr, Int(args))

    # Swap 1: entry increments to 1, yields back
    stack.swap_to_coro()
    assert_equal(counter[], 1)

    # Swap 2: entry resumes, increments to 2, yields back
    stack.swap_to_coro()
    assert_equal(counter[], 2)

    # Swap 3: entry resumes, increments to 3, yields back
    stack.swap_to_coro()
    assert_equal(counter[], 3)

    # Cleanup
    args.unsafe_free()
    counter.unsafe_free()


def test_pool_ref() raises:
    """Pool back-reference can be stored and retrieved."""
    var stack = _UcontextStack(STACK_SIZE)

    # Initially no pool ref
    assert_true(not stack.has_pool_ref(), "pool ref should be null initially")

    # Set a pool ref
    var dummy = unsafe_alloc[NoneType](1)
    stack.set_pool_ref(dummy)
    assert_true(stack.has_pool_ref(), "pool ref should be non-null after set")
    assert_equal(Int(stack.pool_ref()), Int(dummy))

    # Clear pool ref
    stack.set_pool_ref(null_ptr[NoneType, MutUntrackedOrigin]())
    assert_true(not stack.has_pool_ref(), "pool ref should be null after clear")

    dummy.unsafe_free()


def main() raises:
    test_mapped_region_lifecycle()
    test_ucontext_lifecycle()
    test_round_trip()
    test_pingpong()
    test_pool_ref()
    print("All _UcontextStack tests passed.")
