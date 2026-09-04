"""TransferResult — what a completed recv or send hands back.

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
"""


struct TransferResult(Movable):
    """The outcome of one completed recv or send: a byte count and the buffer.

    Fields:
        count: How many bytes the operation moved. For a recv this is
               how many bytes at the front of the buffer are valid — the
               buffer's length is not changed by the operation. For a
               send it is how many bytes of the buffer went out; a short
               send is not an error, so compare it with the length you
               submitted.
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
        the span.

        Returns:
            A span over the transferred bytes.
        """
        return Span(self._buf)[: self.count]

    def take_buffer(deinit self) -> List[UInt8]:
        """Take the buffer back, consuming this result.

        The list comes back exactly as it was submitted — same length,
        same capacity, same storage — with the transferred bytes written
        into its front for a recv, and untouched for a send.

        Returns:
            The buffer the operation used.
        """
        return self._buf^
