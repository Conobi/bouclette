"""Architecture-specific ABI constants for Linux.

Centralizes calling-convention rules that differ between x86_64 and
aarch64. Consumers import named constants instead of hardcoding ABI
math. Each future platform gets its own `socle/<platform>/abi.mojo`.
"""

from std.sys.info import CompilationTarget


@always_inline("nodebug")
def _pick_int[x86: Int, arm: Int]() -> Int:
    """Select an Int value based on the target architecture."""
    comptime if CompilationTarget.is_x86():
        return x86
    else:
        return arm


# x86_64: CALL pushes 8-byte return address, so RSP = 16n - 8 at entry.
# aarch64: BLR stores return in LR register, SP must be 16-byte aligned.
comptime STACK_ENTRY_OFFSET = _pick_int[8, 0]()

# Minimum stack alignment (bytes). 16 on both x86_64 and aarch64.
comptime STACK_ALIGNMENT = 16
