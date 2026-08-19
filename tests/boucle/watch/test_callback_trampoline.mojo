"""Verify _trampoline monomorphises to a thin function pointer."""

from std.memory import Pointer
from std.testing import assert_true, assert_equal
from boucle.watch._callback import _FutureCallback, _trampoline
from boucle.proactor.completion import CompletionFn


struct _TestCallback(_FutureCallback):
    """Minimal _FutureCallback implementor for trampoline validation."""

    var value: Int32

    def __init__(out self):
        """Construct with zero result."""
        self.value = Int32(0)

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.value = move.value

    def set_result(mut self, result: Int32):
        """Store the result.

        Args:
            result: The CQE result value.
        """
        self.value = result


def main() raises:
    # Assign _trampoline[_TestCallback] to a CompletionFn alias.
    # This proves it compiles as a thin function pointer with the exact
    # signature (Pointer[NoneType, MutUntrackedOrigin], Int32, UInt32) -> None.
    var fn_ptr: CompletionFn = _trampoline[_TestCallback]

    # Dispatch through the trampoline to verify runtime correctness.
    # Read back through the same MutUntrackedOrigin pointer to avoid
    # the compiler caching the local value across the opaque call.
    var cb = _TestCallback()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cb))
    )
    fn_ptr(ctx, Int32(42), UInt32(0))
    var readback = ctx.unsafe_bitcast[_TestCallback]()
    assert_equal(readback[].value, Int32(42))

    fn_ptr(ctx, Int32(-111), UInt32(0))
    assert_equal(readback[].value, Int32(-111))

    print("PASS: _trampoline compiles as thin fn pointer and dispatches correctly")
