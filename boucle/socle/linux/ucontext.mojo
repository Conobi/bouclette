"""Ucontext FFI wrappers for stackful coroutines.

Calls libc getcontext/swapcontext via external_call.
Bypasses makecontext entirely by writing gregs[] directly.
"""

from std.ffi import external_call
from std.memory import Pointer, unsafe_memset
from std.memory.alloc import unsafe_alloc
from boucle.socle.linux.raw import (
    UCONTEXT_SIZE,
    UC_STACK_SP_OFFSET,
    UC_STACK_FLAGS_OFFSET,
    UC_STACK_SIZE_OFFSET,
    UC_GREGS_OFFSET,
    REG_RDI,
    REG_RSP,
    REG_RIP,
)
from boucle.socle.linux.abi import STACK_ENTRY_OFFSET, STACK_ALIGNMENT


@always_inline
def alloc_ucontext() -> Pointer[UInt8, MutUntrackedOrigin]:
    """Allocate a zeroed ucontext_t buffer (968 bytes)."""
    var ctx = unsafe_alloc[UInt8](UCONTEXT_SIZE)
    unsafe_memset(ctx, 0, UCONTEXT_SIZE)
    return ctx


@always_inline
def free_ucontext(ctx: Pointer[UInt8, MutUntrackedOrigin]):
    """Free a ucontext_t buffer."""
    ctx.unsafe_free()


@always_inline
def uc_getcontext(ctx: Pointer[UInt8, MutUntrackedOrigin]) raises:
    """Initialize a ucontext_t by saving the current context.

    Args:
        ctx: Pointer to a 968-byte buffer for the ucontext_t.
    """
    var res = external_call["getcontext", Int32](ctx)
    if res != 0:
        raise "getcontext failed"


@always_inline
def uc_swapcontext(
    save_ctx: Pointer[UInt8, MutUntrackedOrigin], load_ctx: Pointer[UInt8, MutUntrackedOrigin]
) raises:
    """Save current context and switch to another.

    Args:
        save_ctx: Where to save the current context.
        load_ctx: Context to switch to.
    """
    var res = external_call["swapcontext", Int32](save_ctx, load_ctx)
    if res != 0:
        raise "swapcontext failed"


def uc_swapcontext_unchecked(
    save_ctx: Pointer[UInt8, MutUntrackedOrigin], load_ctx: Pointer[UInt8, MutUntrackedOrigin]
):
    """Save current context and switch to another (non-raising).

    Used in suspend where raising is not allowed.
    """
    var res = external_call["swapcontext", Int32](save_ctx, load_ctx)
    debug_assert(res == 0, "swapcontext failed")


def setup_context(
    ctx: Pointer[UInt8, MutUntrackedOrigin],
    *,
    stack_ptr: Pointer[UInt8, MutUntrackedOrigin],
    stack_size: UInt,
    entry_addr: Int,
    arg_addr: Int,
) raises:
    """Configure a ucontext for a new coroutine.

    Must call uc_getcontext(ctx) first to initialize the struct,
    then this function overwrites the stack and register fields.

    The entry function receives arg_addr as its first argument register.
    The stack pointer is set to the top of the stack, aligned per the
    platform ABI using arch-dispatched constants from abi.mojo.

    Args:
        ctx: An initialized ucontext_t buffer.
        stack_ptr: Base of the usable stack (past guard page).
        stack_size: Size of the usable stack in bytes.
        entry_addr: Address of the entry function (written to REG_RIP).
        arg_addr: First argument value (written to REG_RDI).
    """
    # Write uc_stack fields
    var ss_sp = ctx.unsafe_offset(UC_STACK_SP_OFFSET).unsafe_bitcast[Pointer[UInt8, MutUntrackedOrigin]]()
    ss_sp[] = stack_ptr
    var ss_flags = ctx.unsafe_offset(UC_STACK_FLAGS_OFFSET).unsafe_bitcast[Int32]()
    ss_flags[] = 0
    var ss_size = ctx.unsafe_offset(UC_STACK_SIZE_OFFSET).unsafe_bitcast[UInt]()
    ss_size[] = stack_size

    var stack_top = Int(stack_ptr) + Int(stack_size)
    var sp = (stack_top & ~(STACK_ALIGNMENT - 1)) - STACK_ENTRY_OFFSET

    # Write gregs
    var gregs = ctx.unsafe_offset(UC_GREGS_OFFSET).unsafe_bitcast[Int64]()
    gregs[unsafe_offset=REG_RIP] = Int64(entry_addr)
    gregs[unsafe_offset=REG_RSP] = Int64(sp)
    gregs[unsafe_offset=REG_RDI] = Int64(arg_addr)
