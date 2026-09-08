from std.sys.intrinsics import llvm_intrinsic, unlikely
from std.sys.info import bit_width_of
from std.memory import Pointer
from std.atomic import Atomic, Ordering


struct _AddOverflowResult(TrivialRegisterPassable):
    var value: UInt32
    var overflow: Bool

@__nonmaterializable(NoneType)
struct AtomicOrdering(TrivialRegisterPassable):
    comptime ACQUIRE = Self(unsafe_id=0)
    comptime RELEASE = Self(unsafe_id=1)
    comptime RELAXED = Self(unsafe_id=2)

    var id: UInt8

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_id: UInt8):
        self.id = unsafe_id

    @always_inline("nodebug")
    def __is__(self, rhs: Self) -> Bool:
        return self.id == rhs.id


@always_inline("nodebug")
def _atomic_load[
    type: DType, //, ordering: AtomicOrdering
](unsafe_ptr: Pointer[Scalar[type], ImmStaticOrigin]) -> Scalar[type]:
    comptime if ordering is AtomicOrdering.ACQUIRE:
        return Atomic[type].load[ordering = Ordering.ACQUIRE](unsafe_ptr)
    elif ordering is AtomicOrdering.RELAXED:
        return Atomic[type].load[ordering = Ordering.RELAXED](unsafe_ptr)
    else:
        comptime assert False, "unsupported atomic ordering"


@always_inline("nodebug")
def _atomic_store[
    type: DType
](unsafe_ptr: Pointer[Scalar[type], ImmStaticOrigin], rhs: Scalar[type]):
    Atomic[type].store[ordering = Ordering.RELEASE](
        unsafe_ptr.unsafe_mut_cast[True](), rhs
    )


@always_inline("nodebug")
def _next_power_of_two(value: UInt32) -> UInt32:
    """Panics on overflow; wraps to 0 without assertions."""
    debug_assert(value <= UInt32(1 << (bit_width_of[UInt32]() - 1)), "result overflow")
    return _one_less_than_next_power_of_two(value) + 1


@always_inline("nodebug")
def _one_less_than_next_power_of_two(value: UInt32) -> UInt32:
    """Cannot overflow; returns `UInt32.MAX` in the overflow case, 0 for 0."""
    if value <= 1:
        return 0

    var p = value - 1
    # Because `p > 0`, it cannot consist entirely of leading zeros.
    # That means the shift is always in-bounds, and some processors
    # (such as Intel pre-Haswell) have more efficient ctlz
    # intrinsics when the argument is non-zero.
    var z = llvm_intrinsic["llvm.ctlz", UInt32, has_side_effect=False](p, True)
    return UInt32.MAX >> z

@always_inline("nodebug")
def _add_with_overflow(lhs: UInt32, rhs: UInt32) -> _AddOverflowResult:
    return llvm_intrinsic[
        "llvm.uadd.with.overflow",
        _AddOverflowResult,
    ](lhs, rhs)

@always_inline("nodebug")
def _checked_add(lhs: UInt32, rhs: UInt32) raises -> UInt32:
    """Raises on overflow."""
    var res = _add_with_overflow(lhs, rhs)
    if unlikely(res.overflow):
        raise "integer overflow"
    return res.value


@always_inline("nodebug")
def _checked_mul(lhs: UInt32, rhs: UInt32) raises -> UInt32:
    """Raises on overflow."""
    var res = llvm_intrinsic[
        "llvm.umul.with.overflow",
        _AddOverflowResult,
    ](lhs, rhs)
    if unlikely(res.overflow):
        raise "integer overflow"
    return res.value
