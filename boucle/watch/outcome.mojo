"""Portable outcome types for completion-based I/O operations.

Decodes operation result codes into portable, domain-specific outcomes.
Each outcome type maps raw kernel results to a small set of discriminated
states that higher-level code can pattern-match on.
"""

from boucle.error import IOError
from boucle.socle.platform import Errno


struct ConnectOutcome(ImplicitlyCopyable, Movable, Equatable, Writable):
    """Decodes a connect(2) result into a portable outcome.

    Discriminates five states via a UInt8 tag:
    - CONNECTED: connect succeeded (connect result == 0).
    - REFUSED: peer actively rejected (ECONNREFUSED).
    - TIMEOUT: connect timed out (ETIMEDOUT).
    - NETWORK_UNREACHABLE: no route to host/network (ENETUNREACH, EHOSTUNREACH).
    - ERROR: any other failure.

    The errno is preserved as a **positive** number — matching `IOError` — so
    ERROR outcomes and the two errnos that share the NETWORK_UNREACHABLE tag
    stay distinguishable. Drivers deliver negated errnos, following the
    kernel completion convention; `from_result` accepts either sign.

    Equality compares the tag only: two outcomes are the same outcome even
    when they carry different errnos.
    """

    comptime CONNECTED = Self(tag=0, raw=0)
    comptime REFUSED = Self(tag=1, raw=Int(-Errno.ECONNREFUSED.id))
    comptime TIMEOUT = Self(tag=2, raw=Int(-Errno.ETIMEDOUT.id))
    comptime NETWORK_UNREACHABLE = Self(tag=3, raw=Int(-Errno.ENETUNREACH.id))
    comptime ERROR = Self(tag=4, raw=0)

    var _tag: UInt8
    var _raw: Int

    @always_inline("nodebug")
    def __init__(out self, *, tag: UInt8, raw: Int):
        """Construct a ConnectOutcome from a tag and a positive errno.

        Args:
            tag: Discriminant (0=CONNECTED .. 4=ERROR).
            raw: The positive errno, or 0 on success.
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
            result: The operation result: 0 on success, otherwise the errno
                    in either sign (drivers deliver it negated).

        Returns:
            The corresponding ConnectOutcome, holding a positive errno.
        """
        var errno = -result if result < 0 else result
        if errno == 0:
            return Self(tag=0, raw=0)
        if errno == Int(-Errno.ECONNREFUSED.id):
            return Self(tag=1, raw=errno)
        if errno == Int(-Errno.ETIMEDOUT.id):
            return Self(tag=2, raw=errno)
        if errno == Int(-Errno.ENETUNREACH.id) or errno == Int(
            -Errno.EHOSTUNREACH.id
        ):
            return Self(tag=3, raw=errno)
        return Self(tag=4, raw=errno)

    @always_inline("nodebug")
    def __eq__(self, rhs: Self) -> Bool:
        """Compare two outcomes by tag, ignoring the errno.

        Args:
            rhs: The outcome to compare against.
        """
        return self._tag == rhs._tag

    @always_inline("nodebug")
    def __ne__(self, rhs: Self) -> Bool:
        """Compare two outcomes by tag, ignoring the errno.

        Args:
            rhs: The outcome to compare against.
        """
        return self._tag != rhs._tag

    @always_inline("nodebug")
    def is_connected(self) -> Bool:
        """Return True if the connect succeeded.
        """
        return self._tag == UInt8(0)

    @always_inline("nodebug")
    def is_refused(self) -> Bool:
        """Return True if the connection was refused.
        """
        return self._tag == UInt8(1)

    @always_inline("nodebug")
    def is_timeout(self) -> Bool:
        """Return True if the connect timed out.
        """
        return self._tag == UInt8(2)

    @always_inline("nodebug")
    def is_network_unreachable(self) -> Bool:
        """Return True if the network or host was unreachable.
        """
        return self._tag == UInt8(3)

    @always_inline("nodebug")
    def is_error(self) -> Bool:
        """Return True if the outcome is an unclassified error.
        """
        return self._tag == UInt8(4)

    @always_inline("nodebug")
    def raw_result(self) -> Int:
        """Return the errno as a positive number.

        Useful for ERROR outcomes where the caller needs the specific errno.

        Returns:
            The positive errno, or 0 when the connect succeeded.
        """
        return self._raw

    @always_inline("nodebug")
    def error(self) -> IOError:
        """Return the outcome's errno as an IOError.

        Bridges to the type every boucle I/O failure raises, so a caller can
        report a failed connect the same way it reports any other error. A
        CONNECTED outcome yields the errno-0 "no error" value.

        Returns:
            An IOError carrying this outcome's errno.
        """
        return IOError.from_errno(self._raw)

    @always_inline
    def write_to[W: Writer](self, mut writer: W):
        """Write a human-readable representation.

        Args:
            writer: The writer to output to.
        """
        if self._tag == UInt8(0):
            writer.write("ConnectOutcome.CONNECTED")
        elif self._tag == UInt8(1):
            writer.write("ConnectOutcome.REFUSED(", self.error(), ")")
        elif self._tag == UInt8(2):
            writer.write("ConnectOutcome.TIMEOUT(", self.error(), ")")
        elif self._tag == UInt8(3):
            writer.write(
                "ConnectOutcome.NETWORK_UNREACHABLE(", self.error(), ")"
            )
        else:
            writer.write("ConnectOutcome.ERROR(", self.error(), ")")
