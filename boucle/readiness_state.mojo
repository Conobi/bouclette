"""Readiness state returned by the OS.

Reports which I/O operations are possible on a resource right now.
Returned via `ReadinessHandler.on_ready()`.
"""


struct Readiness(TrivialRegisterPassable):
    """I/O readiness flags — what the resource is ready for."""

    comptime READABLE = UInt32(1)
    comptime WRITABLE = UInt32(2)
    comptime ERROR = UInt32(4)
    comptime HUP = UInt32(8)
    comptime READ_HUP = UInt32(16)

    var value: UInt32

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value

    @always_inline("nodebug")
    def is_readable(self) -> Bool:
        return self.value & Self.READABLE != 0

    @always_inline("nodebug")
    def is_writable(self) -> Bool:
        return self.value & Self.WRITABLE != 0

    @always_inline("nodebug")
    def is_error(self) -> Bool:
        return self.value & Self.ERROR != 0

    @always_inline("nodebug")
    def is_hup(self) -> Bool:
        return self.value & Self.HUP != 0

    @always_inline("nodebug")
    def is_read_hup(self) -> Bool:
        return self.value & Self.READ_HUP != 0
