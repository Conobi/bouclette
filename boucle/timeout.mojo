"""Portable timeout duration for I/O operations."""


struct Timeout(TrivialRegisterPassable):
    """Duration for I/O timeouts.

    Two Int64 fields: seconds + nanoseconds. On Linux, the driver
    may bitcast a pointer to this struct for zero-copy submission.
    On other platforms, the driver converts as needed.
    """

    var seconds: Int64
    var nanoseconds: Int64

    @always_inline("nodebug")
    def __init__(out self, *, seconds: Int64 = 0, nanoseconds: Int64 = 0):
        """Create a Timeout with explicit seconds and nanoseconds."""
        self.seconds = seconds
        self.nanoseconds = nanoseconds

    @staticmethod
    def from_ms(ms: Int64) -> Self:
        """Create a Timeout from milliseconds."""
        return Self(seconds=ms // 1000, nanoseconds=(ms % 1000) * 1_000_000)
