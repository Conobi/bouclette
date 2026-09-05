"""TransferResult and the typed failures of a completed recv or send.

A completion-based recv or send owns its buffer for the whole operation:
the caller gives the buffer to the loop at submission and gets it back
here, together with the number of bytes that actually moved. Nothing
else can touch the memory in between, which is what makes the kernel
writing into it safe.

Mojo 1.0 cannot destructure a tuple holding a non-copyable value
(`var n, var buf = f^.result()` does not compile), so the pair is a
struct with a name rather than a `Tuple[Int, List[UInt8]]`: read
`count`, look at `transferred()`, and call `take_buffer()` when the
buffer itself is wanted back.

Failure keeps the same promise. `TransferFailed` (recv/send) and
`MessageFailed` (recv_msg/send_msg) are the one error type each
`result()` raises; on an I/O failure they carry the buffer or message
that was in flight, so a caller recovers it from the `except` block.
The reason names why no result exists: `IO` (the completion's errno),
`NOT_DONE` (the loop has not run it yet; the buffer is still in flight),
`LOOP_GONE` (the loop was destroyed first; its destructor abandoned the
buffer). Both are `Writable`, so a bare `raises` caller sees
`"<reason>: <errno name> (<number>)"`.
"""

from boucle.error import IOError
from boucle.net.message import Message
from boucle.socle.platform import ECANCELED, EINVAL


struct TransferResult(Movable):
    """The outcome of one completed recv or send: a byte count and the buffer.

    Fields:
        count: How many bytes the operation moved. For a recv this is
               how many bytes at the front of the buffer are valid — the
               buffer's length is not changed by the operation. For a
               send it is how many bytes of the buffer went out; a short
               send is not an error, so compare it with the length you
               submitted. Under MSG_TRUNC the raw count can exceed the
               buffer; `transferred()` clamps to the buffer's own length
               and never does.
    """

    var count: Int
    var _buf: List[UInt8]

    def __init__(out self, count: Int, var buf: List[UInt8]):
        """Pair a byte count with the buffer the operation used.

        Args:
            count: The number of bytes transferred.
            buf: The buffer, handed back from the loop.
        """
        self.count = count
        self._buf = buf^

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source result to move from.
        """
        self.count = move.count
        self._buf = move._buf^

    def transferred(ref self) -> Span[UInt8, origin_of(self._buf)]:
        """View the bytes that actually moved.

        The first `count` bytes of the buffer: what was received, or
        what was sent. Borrows the buffer, so the result must outlive
        the span. Clamped to the buffer's length: under MSG_TRUNC
        `count` can be larger than the buffer the caller offered.

        Returns:
            A span over the transferred bytes, or the whole buffer when
            `count` exceeds its length.
        """
        return Span(self._buf)[: min(self.count, len(self._buf))]

    def take_buffer(deinit self) -> List[UInt8]:
        """Take the buffer back, consuming this result.

        The list comes back exactly as it was submitted — same length,
        same capacity, same storage — with the transferred bytes written
        into its front for a recv, and untouched for a send.

        Returns:
            The buffer the operation used.
        """
        return self._buf^


# ===----------------------------------------------------------------------=== #
# FailureReason
# ===----------------------------------------------------------------------=== #


struct FailureReason(TrivialRegisterPassable, Equatable, Writable):
    """Why a future's result() had no result to give.

    - IO: the operation completed with an errno; the buffer comes back.
    - NOT_DONE: result() was called before the completion arrived; the
      loop still owns the buffer and releases it when the operation
      finishes.
    - LOOP_GONE: the loop was destroyed before the completion; its
      destructor abandoned the buffer, so there is nothing to return.
    """

    comptime IO = Self(tag=0)
    comptime NOT_DONE = Self(tag=1)
    comptime LOOP_GONE = Self(tag=2)

    var _tag: UInt8

    @always_inline("nodebug")
    def __init__(out self, *, tag: UInt8):
        """Construct a reason from its discriminant.

        Args:
            tag: 0 = IO, 1 = NOT_DONE, 2 = LOOP_GONE.
        """
        debug_assert(tag <= 2, "unknown FailureReason tag")
        self._tag = tag

    @always_inline("nodebug")
    def __eq__(self, rhs: Self) -> Bool:
        """Return True when both name the same reason.

        Args:
            rhs: The reason to compare against.

        Returns:
            True if the tags are equal.
        """
        return self._tag == rhs._tag

    @always_inline("nodebug")
    def __ne__(self, rhs: Self) -> Bool:
        """Return True when the reasons differ.

        Args:
            rhs: The reason to compare against.

        Returns:
            True if the tags differ.
        """
        return self._tag != rhs._tag

    def write_to[W: Writer](self, mut writer: W):
        """Write the reason's name.

        Parameters:
            W: The writer type.

        Args:
            writer: Where the name goes.
        """
        if self._tag == 0:
            writer.write("IO")
        elif self._tag == 1:
            writer.write("NOT_DONE")
        else:
            writer.write("LOOP_GONE")


# ===----------------------------------------------------------------------=== #
# TransferFailed / MessageFailed
# ===----------------------------------------------------------------------=== #


struct TransferFailed(Movable, Writable):
    """Raised by RecvFuture.result and SendFuture.result.

    Fields:
        error: An IOError wrapping the errno. The completion's errno for
               IO; EINVAL for NOT_DONE; ECANCELED for LOOP_GONE.
        reason: Why there is no result.
    """

    var error: IOError
    var reason: FailureReason
    var _buf: Optional[List[UInt8]]

    def __init__(
        out self,
        error: IOError,
        reason: FailureReason,
        var buf: Optional[List[UInt8]],
    ):
        """Construct a failure.

        Prefer the static constructors below (`io`, `not_done`,
        `loop_gone`) — they are the intended path and keep the reason
        paired with its payload for you.

        Args:
            error: The errno to report.
            reason: Why there is no result.
            buf: The buffer to hand back, if any.
        """
        debug_assert(
            reason != FailureReason.IO or Bool(buf),
            "IO reason requires a buffer",
        )
        self.error = error
        self.reason = reason
        self._buf = buf^

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source failure.
        """
        self.error = move.error
        self.reason = move.reason
        self._buf = move._buf^

    @staticmethod
    def io(result: Int, var buf: List[UInt8]) -> Self:
        """Build the IO failure from a negative completion result.

        Args:
            result: The completion result (a negated errno).
            buf: The buffer that was in flight.

        Returns:
            A failure carrying the errno and the buffer.
        """
        return Self(IOError.from_errno(result), FailureReason.IO, Optional(buf^))

    @staticmethod
    def not_done() -> Self:
        """Build the NOT_DONE failure.

        Returns:
            A failure carrying EINVAL and no buffer.
        """
        return Self(
            IOError(positive_errno=EINVAL),
            FailureReason.NOT_DONE,
            Optional[List[UInt8]](),
        )

    @staticmethod
    def loop_gone() -> Self:
        """Build the LOOP_GONE failure.

        Returns:
            A failure carrying ECANCELED and no buffer.
        """
        return Self(
            IOError(positive_errno=ECANCELED),
            FailureReason.LOOP_GONE,
            Optional[List[UInt8]](),
        )

    def take_buffer(deinit self) -> Optional[List[UInt8]]:
        """Take the in-flight buffer back, consuming the failure.

        Returns:
            The buffer for IO; None for NOT_DONE and LOOP_GONE.
        """
        return self._buf^

    def write_to[W: Writer](self, mut writer: W):
        """Write `<reason>: <error>`.

        Parameters:
            W: The writer type.

        Args:
            writer: Where the text goes.
        """
        writer.write(self.reason, ": ", self.error)


struct MessageFailed(Movable, Writable):
    """Raised by RecvMsgFuture.result and SendMsgFuture.result.

    Fields:
        error: An IOError wrapping the errno. The completion's errno for
               IO; EINVAL for NOT_DONE; ECANCELED for LOOP_GONE.
        reason: Why there is no result.
    """

    var error: IOError
    var reason: FailureReason
    var _msg: Optional[Message]

    def __init__(
        out self,
        error: IOError,
        reason: FailureReason,
        var msg: Optional[Message],
    ):
        """Construct a failure.

        Prefer the static constructors below (`io`, `not_done`,
        `loop_gone`) — they are the intended path and keep the reason
        paired with its payload for you.

        Args:
            error: The errno to report.
            reason: Why there is no result.
            msg: The message to hand back, if any.
        """
        debug_assert(
            reason != FailureReason.IO or Bool(msg),
            "IO reason requires a message",
        )
        self.error = error
        self.reason = reason
        self._msg = msg^

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source failure.
        """
        self.error = move.error
        self.reason = move.reason
        self._msg = move._msg^

    @staticmethod
    def io(result: Int, var msg: Message) -> Self:
        """Build the IO failure from a negative completion result.

        Args:
            result: The completion result (a negated errno).
            msg: The message that was in flight.

        Returns:
            A failure carrying the errno and the message.
        """
        return Self(IOError.from_errno(result), FailureReason.IO, Optional(msg^))

    @staticmethod
    def not_done() -> Self:
        """Build the NOT_DONE failure.

        Returns:
            A failure carrying EINVAL and no message.
        """
        return Self(
            IOError(positive_errno=EINVAL),
            FailureReason.NOT_DONE,
            Optional[Message](),
        )

    @staticmethod
    def loop_gone() -> Self:
        """Build the LOOP_GONE failure.

        Returns:
            A failure carrying ECANCELED and no message.
        """
        return Self(
            IOError(positive_errno=ECANCELED),
            FailureReason.LOOP_GONE,
            Optional[Message](),
        )

    def take_message(deinit self) -> Optional[Message]:
        """Take the in-flight message back, consuming the failure.

        Returns:
            The message for IO; None for NOT_DONE and LOOP_GONE.
        """
        return self._msg^

    def write_to[W: Writer](self, mut writer: W):
        """Write `<reason>: <error>`.

        Parameters:
            W: The writer type.

        Args:
            writer: Where the text goes.
        """
        writer.write(self.reason, ": ", self.error)
