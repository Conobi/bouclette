"""Internal callback trait and generic dispatch for Future completion.

The _FutureCallback trait bridges the gap between io_uring's type-erased
completion callbacks (function pointer + void* context) and typed Future
state machines. Each Future implementation conforms to _FutureCallback,
and a single monomorphised _dispatch function casts the context pointer
back to the concrete type and delivers the result.

Not part of the public API.
"""

from std.memory import Pointer


trait _FutureCallback(Movable):
    """Internal trait for Future states.

    Implementors receive CQE results via set_result() and update their
    internal state accordingly. Not part of the public API.
    """

    def set_result(mut self, result: Int):
        """Store the completion result from a CQE.

        Args:
            result: The io_uring CQE result (negative errno on error,
                    non-negative on success).
        """
        ...


def _dispatch[F: _FutureCallback](
    ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
):
    """Generic CQE dispatch to a typed _FutureCallback.

    After monomorphisation this is a plain function pointer compatible with
    CompletionFn — no closure capture, no heap allocation.

    Args:
        ctx: Type-erased pointer to the _FutureCallback implementor.
        result: The io_uring CQE result.
        flags: The io_uring CQE flags (currently unused by _FutureCallback).
    """
    var cb_ptr = ctx.unsafe_bitcast[F]()
    cb_ptr[].set_result(result)
