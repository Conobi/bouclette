"""Backend identifier for I/O driver selection."""

from std.format import Writable, Writer


@fieldwise_init
struct Backend(TrivialRegisterPassable, Equatable, Writable):
    """Identifies which kernel I/O mechanism is active."""

    comptime AUTO = Self(0)
    comptime IO_URING = Self(1)
    comptime EPOLL = Self(2)

    var id: UInt8

    @always_inline("nodebug")
    def __is__(self, rhs: Self) -> Bool:
        return self.id == rhs.id

    @always_inline("nodebug")
    def __isnot__(self, rhs: Self) -> Bool:
        return self.id != rhs.id

    @always_inline("nodebug")
    def __eq__(self, rhs: Self) -> Bool:
        return self.id == rhs.id

    @always_inline("nodebug")
    def __ne__(self, rhs: Self) -> Bool:
        return self.id != rhs.id

    def write_to[W: Writer](self, mut writer: W):
        """Write the mechanism name, so `print(loop.backend())` reads."""
        if self.id == Self.AUTO.id:
            writer.write("auto")
        elif self.id == Self.IO_URING.id:
            writer.write("io_uring")
        elif self.id == Self.EPOLL.id:
            writer.write("epoll")
        else:
            writer.write("unknown(", self.id, ")")
