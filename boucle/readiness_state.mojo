"""Readiness state returned by the OS.

Reports which I/O operations are possible on a resource right now.
Returned via `ReadinessHandler.on_ready()`.
"""

from boucle.socle.linux.raw import (
    EPOLLIN,
    EPOLLOUT,
    EPOLLERR,
    EPOLLHUP,
    EPOLLRDHUP,
)


struct Readiness(TrivialRegisterPassable):
    """I/O readiness flags — what the resource is ready for."""

    var value: UInt32

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value

    @always_inline("nodebug")
    def is_readable(self) -> Bool:
        return self.value & EPOLLIN != 0

    @always_inline("nodebug")
    def is_writable(self) -> Bool:
        return self.value & EPOLLOUT != 0

    @always_inline("nodebug")
    def is_error(self) -> Bool:
        return self.value & EPOLLERR != 0

    @always_inline("nodebug")
    def is_hup(self) -> Bool:
        return self.value & EPOLLHUP != 0

    @always_inline("nodebug")
    def is_read_hup(self) -> Bool:
        return self.value & EPOLLRDHUP != 0
