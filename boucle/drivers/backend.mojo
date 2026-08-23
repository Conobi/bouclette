"""Backend identifier for I/O driver selection."""


@fieldwise_init
struct Backend(TrivialRegisterPassable, Equatable):
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
