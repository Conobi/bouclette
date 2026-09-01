"""Unified ucontext_t layout constants for x86_64 and aarch64.

On x86_64, sizeof(ucontext_t) = 968 (glibc 2.28+).
On aarch64, sizeof(ucontext_t) = 4560 (glibc, no SVE extensions).

Register-name aliases use x86_64 names (REG_RIP, REG_RSP, REG_RDI) on
both arches for API stability. On aarch64 the numeric indices map to
the corresponding aarch64 registers (pc, sp, x0). Stackful coroutine
runtime semantics on aarch64 are out of scope for v1 — the constants
are correct but `setup_context` on aarch64 needs an aarch64-specific
register setup path.

References:
- x86_64: /usr/include/x86_64-linux-gnu/sys/ucontext.h
- aarch64: glibc sysdeps/unix/sysv/linux/aarch64/sys/ucontext.h
"""

from boucle.socle.linux.raw.utils import _pick_int


# Total size of ucontext_t
comptime UCONTEXT_SIZE = _pick_int[968, 4560]()

# uc_stack (stack_t) offsets — LP64-stable, same on both arches
comptime UC_STACK_SP_OFFSET = 16
comptime UC_STACK_FLAGS_OFFSET = 24
comptime UC_STACK_SIZE_OFFSET = 32

# uc_mcontext.gregs offset
comptime UC_GREGS_OFFSET = _pick_int[40, 184]()

# Register indices within gregs[] array (each element is 8 bytes)
comptime REG_R8 = _pick_int[0, 8]()
comptime REG_R9 = _pick_int[1, 9]()
comptime REG_R10 = _pick_int[2, 10]()
comptime REG_R11 = _pick_int[3, 11]()
comptime REG_R12 = _pick_int[4, 12]()
comptime REG_R13 = _pick_int[5, 13]()
comptime REG_R14 = _pick_int[6, 14]()
comptime REG_R15 = _pick_int[7, 15]()
comptime REG_RDI = _pick_int[8, 0]()
comptime REG_RSI = _pick_int[9, 1]()
comptime REG_RBP = _pick_int[10, 29]()
comptime REG_RBX = _pick_int[11, 19]()
comptime REG_RDX = _pick_int[12, 2]()
comptime REG_RAX = _pick_int[13, 0]()
comptime REG_RCX = _pick_int[14, 3]()
comptime REG_RSP = _pick_int[15, 31]()
comptime REG_RIP = _pick_int[16, 32]()
comptime REG_EFL = _pick_int[17, 33]()

# Page size for guard pages
comptime PAGE_SIZE = 4096
