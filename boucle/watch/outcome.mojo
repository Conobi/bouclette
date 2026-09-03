"""Portable outcome types for completion-based I/O operations.

Decodes io_uring CQE result codes into portable, domain-specific outcomes.
Each outcome type maps raw kernel results to a small set of discriminated
states that higher-level code can pattern-match on.
"""

from boucle.error import IOError
from boucle.socle.linux.errno import Errno
from boucle.socle.linux.raw import (
    ECONNREFUSED,
    ETIMEDOUT,
    ENETUNREACH,
    EHOSTUNREACH,
)
from boucle.net.probe import PortStatus


struct ConnectOutcome(ImplicitlyCopyable, Movable, Writable):
    """Decodes a connect(2) CQE result into a portable outcome.

    Discriminates five states via a UInt8 tag:
    - CONNECTED: connect succeeded (CQE result == 0).
    - REFUSED: peer actively rejected (ECONNREFUSED).
    - TIMEOUT: connect timed out (ETIMEDOUT).
    - NETWORK_UNREACHABLE: no route to host/network (ENETUNREACH, EHOSTUNREACH).
    - ERROR: any other failure.

    The raw CQE result is preserved for ERROR cases where callers need
    the specific errno.
    """

    comptime CONNECTED = Self(tag=0, raw=0)
    comptime REFUSED = Self(tag=1, raw=-Int(ECONNREFUSED))
    comptime TIMEOUT = Self(tag=2, raw=-Int(ETIMEDOUT))
    comptime NETWORK_UNREACHABLE = Self(tag=3, raw=-Int(ENETUNREACH))
    comptime ERROR = Self(tag=4, raw=-1)

    var _tag: UInt8
    var _raw: Int

    @always_inline("nodebug")
    def __init__(out self, *, tag: UInt8, raw: Int):
        """Construct a ConnectOutcome from a tag and raw CQE result.

        Args:
            tag: Discriminant (0=CONNECTED .. 4=ERROR).
            raw: The original CQE result code.
        """
        self._tag = tag
        self._raw = raw

    @staticmethod
    @always_inline
    def from_cqe_result(result: Int) -> Self:
        """Decode a connect(2) CQE result into a ConnectOutcome.

        Maps common errno values to specific outcome variants.
        Anything not explicitly matched becomes ERROR.

        Args:
            result: The io_uring CQE res field (0 on success,
                    negative errno on failure).

        Returns:
            The corresponding ConnectOutcome.
        """
        if result == 0:
            return Self(tag=0, raw=result)
        if result == -Int(ECONNREFUSED):
            return Self(tag=1, raw=result)
        if result == -Int(ETIMEDOUT):
            return Self(tag=2, raw=result)
        if result == -Int(ENETUNREACH) or result == -Int(EHOSTUNREACH):
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
        """Return the raw CQE result code.

        Useful for ERROR outcomes where the caller needs the specific errno.

        Returns:
            The original io_uring CQE res field.
        """
        return self._raw

    def port_status(self) -> PortStatus:
        """Map this outcome to a PortStatus for probe compatibility.

        Provides interoperability with the existing probe infrastructure:
        - CONNECTED -> PortStatus.OPEN
        - REFUSED -> PortStatus.CLOSED
        - TIMEOUT, NETWORK_UNREACHABLE, ERROR -> PortStatus.FILTERED

        Returns:
            The corresponding PortStatus.
        """
        if self._tag == UInt8(0):
            return PortStatus.OPEN
        if self._tag == UInt8(1):
            return PortStatus.CLOSED
        return PortStatus.FILTERED

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
