"""Tests for ucontext FFI wrappers.

Validates the complete ucontext round-trip:
- external_call to getcontext/swapcontext works
- gregs offsets (REG_RIP, REG_RSP, REG_RDI) are correct
- Function pointer address is obtainable from Mojo
- Stack alignment is correct (x86_64 ABI)
- Context save/restore across multiple swaps is reliable
"""

from boucle._sys.linux.ucontext import (
    alloc_ucontext,
    free_ucontext,
    uc_getcontext,
    uc_swapcontext,
    setup_context,
)
from boucle._sys.linux.mm import (
    mmap_anonymous,
    munmap,
    mprotect,
    MapFlags,
    ProtFlags,
)
from boucle._sys.linux.raw import PAGE_SIZE, UCONTEXT_SIZE
from std.memory import UnsafePointer, memset
from std.memory.unsafe_pointer import alloc
from std.testing import assert_equal, assert_true
from std.ffi import external_call

comptime STACK_SIZE = 64 * 1024  # 64KB usable stack


# --- Trampolines ---
#
# These run on a separately allocated stack via swapcontext.
# They receive arguments through REG_RDI as a raw integer address
# pointing to a packed Int array: [caller_ctx_addr, shared_addr].
# They must swap back to the caller context when done.


def _trampoline_write42(args_raw: Int):
    """Write 42 to shared memory and swap back.

    args_raw -> Int[2]: [caller_ctx_addr, shared_addr].
    """
    var args = UnsafePointer[Int, MutUntrackedOrigin](unsafe_from_address=args_raw)
    var caller_ctx = UnsafePointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=args[0]
    )
    var shared = UnsafePointer[Int, MutUntrackedOrigin](
        unsafe_from_address=args[1]
    )
    shared[] = 42
    # Swap back to caller — allocate a throwaway save buffer
    var dummy = alloc[UInt8](UCONTEXT_SIZE)
    memset(dummy, 0, UCONTEXT_SIZE)
    _ = external_call["swapcontext", Int32](dummy, caller_ctx)
    # dummy.free() intentionally omitted — unreachable after final swap


def _trampoline_pingpong(args_raw: Int):
    """Increment a shared counter 3 times, yielding between each.

    args_raw -> Int[2]: [caller_ctx_addr, counter_addr].
    """
    var args = UnsafePointer[Int, MutUntrackedOrigin](unsafe_from_address=args_raw)
    var caller_ctx = UnsafePointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=args[0]
    )
    var counter = UnsafePointer[Int, MutUntrackedOrigin](
        unsafe_from_address=args[1]
    )

    # Allocate our own save-context for resumption
    var my_ctx = alloc[UInt8](UCONTEXT_SIZE)
    memset(my_ctx, 0, UCONTEXT_SIZE)

    # Round 1: increment and yield
    counter[] = counter[] + 1
    _ = external_call["swapcontext", Int32](my_ctx, caller_ctx)

    # Round 2: resumed here after caller swaps back to us
    counter[] = counter[] + 1
    _ = external_call["swapcontext", Int32](my_ctx, caller_ctx)

    # Round 3: final increment and yield
    counter[] = counter[] + 1
    _ = external_call["swapcontext", Int32](my_ctx, caller_ctx)
    # my_ctx.free() intentionally omitted — unreachable after final swap


# --- Tests ---


def test_getcontext() raises:
    """Getcontext initializes a ucontext_t buffer without crashing."""
    var ctx = alloc_ucontext()
    uc_getcontext(ctx)
    # Reaching here without segfault proves the FFI call and buffer size are correct
    free_ucontext(ctx)


def test_ucontext_round_trip() raises:
    """Single swap to trampoline and back validates the full FFI round-trip.

    This is the critical risk gate: it proves that getcontext, swapcontext,
    gregs manipulation, function pointer extraction, and stack setup all work.
    """
    var shared = alloc[Int](1)
    shared[] = 0

    var caller_ctx = alloc_ucontext()
    var coro_ctx = alloc_ucontext()

    # Pack trampoline args: [caller_ctx address, shared address]
    var args = alloc[Int](2)
    args[0] = Int(caller_ctx)
    args[1] = Int(shared)

    # Allocate stack: guard page (PROT_NONE) + usable region (RW)
    var total_size = PAGE_SIZE + STACK_SIZE
    var stack_mem = mmap_anonymous(
        len=UInt(total_size),
        prot=ProtFlags.READ | ProtFlags.WRITE,
        flags=MapFlags.PRIVATE,
    )
    mprotect(unsafe_ptr=stack_mem, len=UInt(PAGE_SIZE), prot=ProtFlags.NONE)
    var usable_stack = UnsafePointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(stack_mem) + PAGE_SIZE
    )

    # Initialize coro_ctx via getcontext, then overwrite registers
    uc_getcontext(coro_ctx)

    # Extract trampoline function address
    var f = _trampoline_write42
    var fn_addr = Int(UnsafePointer(to=f).bitcast[Int]()[])
    assert_true(fn_addr != 0, "function pointer address must be non-zero")

    setup_context(
        coro_ctx,
        stack_ptr=usable_stack,
        stack_size=UInt(STACK_SIZE),
        entry_addr=fn_addr,
        arg_addr=Int(args),
    )

    # Swap: trampoline runs on the new stack, writes 42, swaps back
    uc_swapcontext(caller_ctx, coro_ctx)

    # Verify the trampoline ran
    assert_equal(shared[], 42)

    # Cleanup
    munmap(unsafe_ptr=stack_mem, len=UInt(total_size))
    free_ucontext(caller_ctx)
    free_ucontext(coro_ctx)
    shared.free()
    args.free()


def test_pingpong() raises:
    """Multiple context switches validate that save/restore is reliable.

    The caller and coroutine swap back and forth 3 times, with the
    coroutine incrementing a shared counter at each step.
    """
    var counter = alloc[Int](1)
    counter[] = 0

    var caller_ctx = alloc_ucontext()
    var coro_ctx = alloc_ucontext()

    var args = alloc[Int](2)
    args[0] = Int(caller_ctx)
    args[1] = Int(counter)

    var total_size = PAGE_SIZE + STACK_SIZE
    var stack_mem = mmap_anonymous(
        len=UInt(total_size),
        prot=ProtFlags.READ | ProtFlags.WRITE,
        flags=MapFlags.PRIVATE,
    )
    mprotect(unsafe_ptr=stack_mem, len=UInt(PAGE_SIZE), prot=ProtFlags.NONE)
    var usable_stack = UnsafePointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(stack_mem) + PAGE_SIZE
    )

    uc_getcontext(coro_ctx)

    var f = _trampoline_pingpong
    var fn_addr = Int(UnsafePointer(to=f).bitcast[Int]()[])

    setup_context(
        coro_ctx,
        stack_ptr=usable_stack,
        stack_size=UInt(STACK_SIZE),
        entry_addr=fn_addr,
        arg_addr=Int(args),
    )

    # Swap 1: trampoline increments to 1, yields back
    uc_swapcontext(caller_ctx, coro_ctx)
    assert_equal(counter[], 1)

    # Swap 2: trampoline resumes, increments to 2, yields back
    uc_swapcontext(caller_ctx, coro_ctx)
    assert_equal(counter[], 2)

    # Swap 3: trampoline resumes, increments to 3, yields back
    uc_swapcontext(caller_ctx, coro_ctx)
    assert_equal(counter[], 3)

    # Cleanup
    munmap(unsafe_ptr=stack_mem, len=UInt(total_size))
    free_ucontext(caller_ctx)
    free_ucontext(coro_ctx)
    counter.free()
    args.free()


def main() raises:
    test_getcontext()
    test_ucontext_round_trip()
    test_pingpong()
    print("All ucontext tests passed.")
