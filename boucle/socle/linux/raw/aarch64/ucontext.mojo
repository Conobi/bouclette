"""aarch64 glibc ucontext_t layout constants.

Reference: glibc `sysdeps/unix/sysv/linux/aarch64/sys/ucontext.h`.

Note: Boucle's stackful coroutine code currently writes into `gregs[]`
using x86_64-named register indices (REG_RIP / REG_RSP / REG_RDI). The
aarch64 mcontext layout is incompatible (uses `regs[0..30]`, `sp`, `pc`,
`pstate`). The aliases below keep the SYMBOL NAMES stable so the facade
re-export list does not change and stackful's import resolves, but the
NUMERIC offsets are aarch64-correct only for the stack_t portion.
Calling `setup_context` on aarch64 will produce wrong register state at
runtime — stackful coroutines on aarch64 are out of scope for v1.
"""

# Total size of ucontext_t on aarch64 glibc (no SVE extensions).
# Glibc rounds up; 4560 is safe across recent glibc versions.
comptime UCONTEXT_SIZE = 4560

# uc_stack (stack_t) offsets within ucontext_t -- LP64 stack_t layout is
# arch-stable, so these match x86_64.
comptime UC_STACK_SP_OFFSET = 16      # uc_stack.ss_sp    (void*)
comptime UC_STACK_FLAGS_OFFSET = 24   # uc_stack.ss_flags (int)
comptime UC_STACK_SIZE_OFFSET = 32    # uc_stack.ss_size  (size_t)

# uc_mcontext.regs offset within ucontext_t on aarch64 glibc.
# (Layout: uc_flags=0, uc_link=8, uc_stack=16, uc_sigmask=40 [128B],
#  uc_mcontext starts at 176; first field is `fault_address` u64, then
#  `regs[31]` u64 array starting at offset 184.)
comptime UC_GREGS_OFFSET = 184

# Register-name aliases. aarch64 mcontext has regs[0..30], sp, pc,
# pstate -- no direct mapping to x86_64 named registers. v1 stubs map
# x86_64 names to indices in aarch64's regs[] for SYMBOL-LEVEL
# compatibility only; runtime semantics differ.
comptime REG_R8 = 8
comptime REG_R9 = 9
comptime REG_R10 = 10
comptime REG_R11 = 11
comptime REG_R12 = 12
comptime REG_R13 = 13
comptime REG_R14 = 14
comptime REG_R15 = 15
comptime REG_RDI = 0  # first arg on aarch64 is x0
comptime REG_RSI = 1
comptime REG_RBP = 29  # aarch64 fp is x29
comptime REG_RBX = 19
comptime REG_RDX = 2
comptime REG_RAX = 0
comptime REG_RCX = 3
comptime REG_RSP = 31  # `sp` lives at offset 31*8 from gregs[0] on aarch64 mcontext
comptime REG_RIP = 32  # `pc` lives at offset 32*8 from gregs[0]
comptime REG_EFL = 33  # `pstate`

# Page size for guard pages (aarch64 supports 4K, 16K, 64K pages;
# Linux default is 4K and Mojo's stackful coroutines assume 4K).
comptime PAGE_SIZE = 4096
