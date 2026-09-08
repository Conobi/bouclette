"""Per-operation completion token for callback-based I/O dispatch.

Each I/O operation carries a caller-owned Completion whose pointer
is stored as the operation user_data. On completion arrival, the event
loop recovers the Completion pointer and invokes its callback with
the result.
"""

from std.collections import Optional
from std.memory import Pointer
from boucle.socle.platform import (
    IORING_CQE_BUFFER_SHIFT,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
)
from boucle.socle.ptr import null_ptr


# Function-pointer type for completion callbacks.
# Signature: (context_ptr, result, flags) -> None
comptime CompletionFn = def (Pointer[NoneType, MutUntrackedOrigin], Int, UInt32) thin -> None


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
        self.invoke = move.invoke
        self.context = move.context

    def fire(self, result: Int, flags: UInt32):
        """Dispatch this completion's callback.

        Args:
            result: The operation result (syscall return value).
            flags: The operation flags.
        """
        self.invoke(self.context, result, flags)

    @staticmethod
    def _noop(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Default no-op callback."""
        pass


# ── Completion flag decoders ──────────────────────────────────────────────────


def buffer_id(flags: UInt32) -> Optional[UInt16]:
    """Return the provided-buffer id a completion's flags name, if any.

    Set when the operation was submitted with buffer selection and the
    kernel (or the epoll emulation) picked a buffer: bit 0 is the marker
    and bits 16..31 carry the id.

    Args:
        flags: The flags passed to the completion callback.

    Returns:
        The buffer id, or None when no buffer was selected.
    """
    if (flags & UInt32(IORING_CQE_F_BUFFER)) == 0:
        return None
    return UInt16(flags >> UInt32(IORING_CQE_BUFFER_SHIFT))


def has_more(flags: UInt32) -> Bool:
    """Return True when a multishot operation stays armed after this completion.

    A completion without this bit is the operation's last; a multishot
    submission must be re-armed to deliver again.

    Args:
        flags: The flags passed to the completion callback.

    Returns:
        True if more completions will follow from the same submission.
    """
    return (flags & UInt32(IORING_CQE_F_MORE)) != 0
