from std.sys import inlined_assembly
from std.sys.info import CompilationTarget


@always_inline("nodebug")
def syscall[
    nr: UInt64,
    result_type: TrivialRegisterPassable,
    *,
    has_side_effect: Bool = True,
    uses_memory: Bool = True,
]() -> result_type:
    """Syscall with 0 arguments."""

    comptime if CompilationTarget.is_x86():
        comptime if uses_memory:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,~{rcx},~{r11},~{memory}",
                has_side_effect = has_side_effect,
            ](nr)
        else:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,~{rcx},~{r11}",
                has_side_effect = has_side_effect,
            ](nr)
    else:
        comptime if uses_memory:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},~{cc},~{memory}",
                has_side_effect = has_side_effect,
            ](nr)
        else:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},~{cc}",
                has_side_effect = has_side_effect,
            ](nr)


@always_inline("nodebug")
def syscall[
    nr: UInt64,
    result_type: TrivialRegisterPassable,
    *,
    has_side_effect: Bool = True,
    uses_memory: Bool = True,
    T0: TrivialRegisterPassable,
](arg0: T0) -> result_type:
    """Syscall with 1 argument."""

    comptime if CompilationTarget.is_x86():
        comptime if uses_memory:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},~{rcx},~{r11},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0)
        else:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},~{rcx},~{r11}",
                has_side_effect = has_side_effect,
            ](nr, arg0)
    else:
        comptime if uses_memory:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,~{cc},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0)
        else:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,~{cc}",
                has_side_effect = has_side_effect,
            ](nr, arg0)


@always_inline("nodebug")
def syscall[
    nr: UInt64,
    result_type: TrivialRegisterPassable,
    *,
    has_side_effect: Bool = True,
    uses_memory: Bool = True,
    T0: TrivialRegisterPassable,
    T1: TrivialRegisterPassable,
](arg0: T0, arg1: T1) -> result_type:
    """Syscall with 2 arguments."""

    comptime if CompilationTarget.is_x86():
        comptime if uses_memory:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},~{rcx},~{r11},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1)
        else:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},~{rcx},~{r11}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1)
    else:
        comptime if uses_memory:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},~{cc},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1)
        else:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},~{cc}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1)


@always_inline("nodebug")
def syscall[
    nr: UInt64,
    result_type: TrivialRegisterPassable,
    *,
    has_side_effect: Bool = True,
    uses_memory: Bool = True,
    T0: TrivialRegisterPassable,
    T1: TrivialRegisterPassable,
    T2: TrivialRegisterPassable,
](arg0: T0, arg1: T1, arg2: T2) -> result_type:
    """Syscall with 3 arguments."""

    comptime if CompilationTarget.is_x86():
        comptime if uses_memory:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2)
        else:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},{rdx},~{rcx},~{r11}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2)
    else:
        comptime if uses_memory:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},{x2},~{cc},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2)
        else:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},{x2},~{cc}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2)


@always_inline("nodebug")
def syscall[
    nr: UInt64,
    result_type: TrivialRegisterPassable,
    *,
    has_side_effect: Bool = True,
    uses_memory: Bool = True,
    T0: TrivialRegisterPassable,
    T1: TrivialRegisterPassable,
    T2: TrivialRegisterPassable,
    T3: TrivialRegisterPassable,
](arg0: T0, arg1: T1, arg2: T2, arg3: T3) -> result_type:
    """Syscall with 4 arguments."""

    comptime if CompilationTarget.is_x86():
        comptime if uses_memory:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},{rdx},{r10},~{rcx},~{r11},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3)
        else:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},{rdx},{r10},~{rcx},~{r11}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3)
    else:
        comptime if uses_memory:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},{x2},{x3},~{cc},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3)
        else:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},{x2},{x3},~{cc}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3)


@always_inline("nodebug")
def syscall[
    nr: UInt64,
    result_type: TrivialRegisterPassable,
    *,
    has_side_effect: Bool = True,
    uses_memory: Bool = True,
    T0: TrivialRegisterPassable,
    T1: TrivialRegisterPassable,
    T2: TrivialRegisterPassable,
    T3: TrivialRegisterPassable,
    T4: TrivialRegisterPassable,
](arg0: T0, arg1: T1, arg2: T2, arg3: T3, arg4: T4) -> result_type:
    """Syscall with 5 arguments."""

    comptime if CompilationTarget.is_x86():
        comptime if uses_memory:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},{rdx},{r10},{r8},~{rcx},~{r11},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3, arg4)
        else:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},{rdx},{r10},{r8},~{rcx},~{r11}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3, arg4)
    else:
        comptime if uses_memory:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},{x2},{x3},{x4},~{cc},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3, arg4)
        else:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},{x2},{x3},{x4},~{cc}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3, arg4)


@always_inline("nodebug")
def syscall[
    nr: UInt64,
    result_type: TrivialRegisterPassable,
    *,
    has_side_effect: Bool = True,
    uses_memory: Bool = True,
    T0: TrivialRegisterPassable,
    T1: TrivialRegisterPassable,
    T2: TrivialRegisterPassable,
    T3: TrivialRegisterPassable,
    T4: TrivialRegisterPassable,
    T5: TrivialRegisterPassable,
](arg0: T0, arg1: T1, arg2: T2, arg3: T3, arg4: T4, arg5: T5) -> result_type:
    """Syscall with 6 arguments."""

    comptime if CompilationTarget.is_x86():
        comptime if uses_memory:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},{rdx},{r10},{r8},{r9},~{rcx},~{r11},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3, arg4, arg5)
        else:
            return inlined_assembly[
                "syscall",
                result_type,
                constraints = "={rax},0,{rdi},{rsi},{rdx},{r10},{r8},{r9},~{rcx},~{r11}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3, arg4, arg5)
    else:
        comptime if uses_memory:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},{x2},{x3},{x4},{x5},~{cc},~{memory}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3, arg4, arg5)
        else:
            return inlined_assembly[
                "svc #0",
                result_type,
                constraints = "={x0},{x8},0,{x1},{x2},{x3},{x4},{x5},~{cc}",
                has_side_effect = has_side_effect,
            ](nr, arg0, arg1, arg2, arg3, arg4, arg5)
