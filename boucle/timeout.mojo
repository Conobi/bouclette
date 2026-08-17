"""Portable timeout duration for I/O operations."""


struct Timeout(TrivialRegisterPassable):
    """Duration for I/O timeouts, replacing platform-specific __kernel_timespec.

    Layout is deliberately identical to Linux's __kernel_timespec
    (two Int64 fields: seconds + nanoseconds) so that on Linux, a
    pointer to Timeout can be bitcast to __kernel_timespec without
    copying. On other platforms, the driver converts as needed.
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
