"""Platform dispatch facade.

End users do not import from this package directly. Internal Boucle
consumers use these comptime parameters to address syscalls and structs
without hardcoding the active OS or arch.

Notes on the predicates used:

- OS detection goes through `CompilationTarget.is_linux()` /
  `is_macos()`. Mojo 1.0.0b1's `sys.info` does not expose `is_windows`,
  so `is_windows` is derived as "not linux and not macos". When a third
  hosted OS (BSD, etc.) lands in `CompilationTarget`, this expression
  needs to be tightened.
- Arch detection uses `CompilationTarget.is_x86()` for x86_64 (Mojo
  only targets 64-bit x86 today) and `CompilationTarget.has_neon()` as
  a proxy for aarch64. NEON is mandatory in the ARMv8-A baseline, so
  every aarch64 target Mojo supports has it; no aarch64-without-NEON
  variant exists in practice. If the stdlib later exposes a direct
  `is_aarch64()`, switch to it.
"""

from std.sys.info import CompilationTarget

comptime is_linux: Bool = CompilationTarget.is_linux()
comptime is_darwin: Bool = CompilationTarget.is_macos()
comptime is_windows: Bool = (
    not CompilationTarget.is_linux() and not CompilationTarget.is_macos()
)

comptime is_x86_64: Bool = CompilationTarget.is_x86()
comptime is_aarch64: Bool = CompilationTarget.has_neon()
