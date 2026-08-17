"""Coroutine phase constants and configuration defaults."""

# Phase constants
comptime CORO_CREATED: UInt8 = 0
comptime CORO_RUNNING: UInt8 = 1
comptime CORO_SUSPENDED: UInt8 = 2
comptime CORO_DONE: UInt8 = 3

# Default stack size (64 KB usable)
comptime DEFAULT_STACK_SIZE: UInt = 65536

# Magic canary for _CoroInner integrity validation
comptime CORO_MAGIC: UInt64 = 0xC0C0_CAFE_B0C1_E000
