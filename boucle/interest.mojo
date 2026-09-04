"""Interest flags for readiness-based I/O.

Declares what I/O events you care about on a resource.
Used with `ReadinessLoop.register()` to tell the OS what to watch for.
"""


struct Interest(TrivialRegisterPassable, Defaultable):
    """I/O interest flags — what events to monitor."""

    comptime READABLE = Self(1)
    comptime WRITABLE = Self(2)
    comptime EDGE_TRIGGERED = Self(4)
    comptime ONESHOT = Self(8)

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value

    @always_inline("nodebug")
    def __or__(self, rhs: Self) -> Self:
        return self.value | rhs.value

    @always_inline("nodebug")
    def __ior__(mut self, rhs: Self):
        self = self | rhs

    @always_inline("nodebug")
    def is_readable(self) -> Bool:
        return self.value & Self.READABLE.value != 0

    @always_inline("nodebug")
    def is_writable(self) -> Bool:
        return self.value & Self.WRITABLE.value != 0

    @always_inline("nodebug")
    def is_edge_triggered(self) -> Bool:
        return self.value & Self.EDGE_TRIGGERED.value != 0

    @always_inline("nodebug")
    def is_oneshot(self) -> Bool:
        return self.value & Self.ONESHOT.value != 0
