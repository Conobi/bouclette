"""Portable readiness event returned by ReadinessDriver.poll().

A ReadinessEvent pairs an opaque Token (for correlating the event
with the registered file descriptor) with a Readiness bitmask
describing which I/O operations are currently possible.
"""

from boucle.token import Token
from boucle.readiness_state import Readiness


struct ReadinessEvent(TrivialRegisterPassable):
    """A single readiness notification from the kernel."""

    var token: Token
    var readiness: Readiness

    @always_inline("nodebug")
    def __init__(out self, token: Token, readiness: Readiness):
        """Construct a readiness event.

        Args:
            token: Opaque token identifying the registered resource.
            readiness: Bitmask of ready I/O operations.
        """
        self.token = token
        self.readiness = readiness
