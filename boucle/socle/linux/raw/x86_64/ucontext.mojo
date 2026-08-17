"""x86_64 glibc ucontext_t layout constants.

These offsets are specific to x86_64 Linux with glibc (not musl).
sizeof(ucontext_t) = 968 on glibc 2.28+.

Reference: /usr/include/x86_64-linux-gnu/sys/ucontext.h
"""

# Total size of ucontext_t on x86_64 glibc
comptime UCONTEXT_SIZE = 968

# uc_stack (stack_t) offsets within ucontext_t
comptime UC_STACK_SP_OFFSET = 16      # uc_stack.ss_sp    (void*)
comptime UC_STACK_FLAGS_OFFSET = 24   # uc_stack.ss_flags (int)
comptime UC_STACK_SIZE_OFFSET = 32    # uc_stack.ss_size  (size_t)

# uc_mcontext.gregs offset within ucontext_t
# On x86_64, uc_mcontext starts at offset 40 and gregs is the first field
comptime UC_GREGS_OFFSET = 40

# Register indices within gregs[] array (each element is 8 bytes / Int64)
comptime REG_R8 = 0
comptime REG_R9 = 1
comptime REG_R10 = 2
comptime REG_R11 = 3
comptime REG_R12 = 4
comptime REG_R13 = 5
comptime REG_R14 = 6
comptime REG_R15 = 7
comptime REG_RDI = 8
comptime REG_RSI = 9
comptime REG_RBP = 10
comptime REG_RBX = 11
comptime REG_RDX = 12
comptime REG_RAX = 13
comptime REG_RCX = 14
comptime REG_RSP = 15
comptime REG_RIP = 16
comptime REG_EFL = 17

# Page size for guard pages
comptime PAGE_SIZE = 4096
