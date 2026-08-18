"""Per-operation completion token for callback-based I/O dispatch.

Each io_uring operation carries a caller-owned Completion whose pointer
is stored as the SQE user_data. On CQE arrival, the event loop recovers
the Completion pointer and invokes its callback with the result.
"""

from std.memory import Pointer
from boucle.socle.ptr import null_ptr


# Function-pointer type for completion callbacks.
# Signature: (context_ptr, cqe_result, cqe_flags) -> None
comptime CompletionFn = def (Pointer[NoneType, MutUntrackedOrigin], Int32, UInt32) thin -> None


struct Completion(Movable):
    """Caller-owned completion token (16 bytes on x86_64).

    Fields:
        invoke: Callback fired on operation completion.
        context: Pointer to the parent struct owning this Completion.
    """

    var invoke: CompletionFn
    var context: Pointer[NoneType, MutUntrackedOrigin]

    def __init__(out self):
        """Construct an uninitialized Completion. Wire before submitting."""
        self.invoke = Self._noop
        self.context = null_ptr[NoneType, MutUntrackedOrigin]()

    def __init__(
        out self,
        invoke: CompletionFn,
        context: Pointer[NoneType, MutUntrackedOrigin],
    ):
        """Construct a wired Completion ready for submission.

        Args:
            invoke: Callback function pointer.
            context: Pointer to the parent (type-erased).
        """
        self.invoke = invoke
        self.context = context

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.invoke = move.invoke
        self.context = move.context

    def fire(self, result: Int32, flags: UInt32):
        """Dispatch this completion's callback.

        Args:
            result: The io_uring CQE result (syscall return value).
            flags: The io_uring CQE flags.
        """
        self.invoke(self.context, result, flags)

    @staticmethod
    def _noop(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Default no-op callback."""
        pass
