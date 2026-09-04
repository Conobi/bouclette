"""Portable outcome types for completion-based I/O operations.

Decodes operation result codes into portable, domain-specific outcomes.
Each outcome type maps raw kernel results to a small set of discriminated
states that higher-level code can pattern-match on.
"""

from boucle.error import IOError
from boucle.socle.linux.errno import Errno


struct ConnectOutcome(ImplicitlyCopyable, Movable, Writable):
    """Decodes a connect(2) result into a portable outcome.

    Discriminates five states via a UInt8 tag:
    - CONNECTED: connect succeeded (connect result == 0).
    - REFUSED: peer actively rejected (ECONNREFUSED).
    - TIMEOUT: connect timed out (ETIMEDOUT).
    - NETWORK_UNREACHABLE: no route to host/network (ENETUNREACH, EHOSTUNREACH).
    - ERROR: any other failure.

    The raw operation result is preserved for ERROR cases where callers need
    the specific errno.
    """

    comptime CONNECTED = Self(tag=0, raw=0)
    comptime REFUSED = Self(tag=1, raw=-Int(Errno.ECONNREFUSED.id))
    comptime TIMEOUT = Self(tag=2, raw=-Int(Errno.ETIMEDOUT.id))
    comptime NETWORK_UNREACHABLE = Self(tag=3, raw=-Int(Errno.ENETUNREACH.id))
    comptime ERROR = Self(tag=4, raw=-1)

    var _tag: UInt8
    var _raw: Int

    @always_inline("nodebug")
    def __init__(out self, *, tag: UInt8, raw: Int):
        """Construct a ConnectOutcome from a tag and raw operation result.

        Args:
            tag: Discriminant (0=CONNECTED .. 4=ERROR).
            raw: The original operation result code.
        """
        self._tag = tag
        self._raw = raw

    @staticmethod
    @always_inline
    def from_result(result: Int) -> Self:
        """Decode a connect(2) operation result into a ConnectOutcome.

        Maps common errno values to specific outcome variants.
        Anything not explicitly matched becomes ERROR.

        Args:
            result: The operation result (0 on success,
                    negative errno on failure).

        Returns:
            The corresponding ConnectOutcome.
        """
        if result == 0:
            return Self(tag=0, raw=result)
        if result == Int(Errno.ECONNREFUSED.id):
            return Self(tag=1, raw=result)
        if result == Int(Errno.ETIMEDOUT.id):
            return Self(tag=2, raw=result)
        if result == Int(Errno.ENETUNREACH.id) or result == Int(
            Errno.EHOSTUNREACH.id
        ):
            return Self(tag=3, raw=result)
        return Self(tag=4, raw=result)

    @always_inline("nodebug")
    def is_connected(self) -> Bool:
        """Return True if the connect succeeded.

        Returns:
            True when the outcome is CONNECTED.
        """
        return self._tag == UInt8(0)

    @always_inline("nodebug")
    def is_refused(self) -> Bool:
        """Return True if the connection was refused.

        Returns:
            True when the outcome is REFUSED.
        """
        return self._tag == UInt8(1)

    @always_inline("nodebug")
    def is_timeout(self) -> Bool:
        """Return True if the connect timed out.

        Returns:
            True when the outcome is TIMEOUT.
        """
        return self._tag == UInt8(2)

    @always_inline("nodebug")
    def is_network_unreachable(self) -> Bool:
        """Return True if the network or host was unreachable.

        Returns:
            True when the outcome is NETWORK_UNREACHABLE.
        """
        return self._tag == UInt8(3)

    @always_inline("nodebug")
    def is_error(self) -> Bool:
        """Return True if the outcome is an unclassified error.

        Returns:
            True when the outcome is ERROR.
        """
        return self._tag == UInt8(4)

    @always_inline("nodebug")
    def raw_result(self) -> Int:
        """Return the raw operation result code.

        Useful for ERROR outcomes where the caller needs the specific errno.

        Returns:
            The original operation result.
        """
        return self._raw

    @always_inline
    def write_to[W: Writer](self, mut writer: W):
        """Write a human-readable representation.

        Args:
            writer: The writer to output to.
        """
        if self._tag == UInt8(0):
            writer.write("ConnectOutcome.CONNECTED")
        elif self._tag == UInt8(1):
            writer.write("ConnectOutcome.REFUSED(", self._raw, ")")
        elif self._tag == UInt8(2):
            writer.write("ConnectOutcome.TIMEOUT(", self._raw, ")")
        elif self._tag == UInt8(3):
            writer.write(
                "ConnectOutcome.NETWORK_UNREACHABLE(", self._raw, ")"
            )
        else:
            writer.write("ConnectOutcome.ERROR(", self._raw, ")")
