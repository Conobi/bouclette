"""Coroutine phase type and configuration defaults."""


struct Phase(TrivialRegisterPassable, Equatable, Writable):
    """Coroutine lifecycle phase.

    Encodes the four states of a stackful coroutine:
    CREATED -> RUNNING <-> SUSPENDED -> DONE
    """

    comptime CREATED = Self(0)
    comptime RUNNING = Self(1)
    comptime SUSPENDED = Self(2)
    comptime DONE = Self(3)

    var _value: UInt8

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt8):
        """Initialize a Phase from a raw UInt8 value."""
        self._value = value

    @always_inline("nodebug")
    def __eq__(self, rhs: Self) -> Bool:
        """Check equality between two Phase values."""
        return self._value == rhs._value

    @always_inline("nodebug")
    def __ne__(self, rhs: Self) -> Bool:
        """Check inequality between two Phase values."""
        return self._value != rhs._value

    def write_to[W: Writer](self, mut writer: W):
        """Write a human-readable phase name."""
        if self._value == 0:
            writer.write("CREATED")
        elif self._value == 1:
            writer.write("RUNNING")
        elif self._value == 2:
            writer.write("SUSPENDED")
        elif self._value == 3:
            writer.write("DONE")
        else:
            writer.write("UNKNOWN(", self._value, ")")

# Default stack size (64 KB usable)
comptime DEFAULT_STACK_SIZE: UInt = 65536

# Magic canary for _CoroInner integrity validation
comptime CORO_MAGIC: UInt64 = 0xC0C0_CAFE_B0C1_E000
