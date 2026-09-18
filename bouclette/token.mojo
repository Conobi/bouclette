"""Opaque token for correlating I/O operations with completions."""


struct Token(TrivialRegisterPassable, Equatable):
    """Opaque token for correlating I/O operations with completions."""

    var value: UInt64

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt64):
        self.value = value

    @always_inline("nodebug")
    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    @always_inline("nodebug")
    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value
