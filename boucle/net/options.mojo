"""Portable socket option enumerations.

Wraps platform-specific constants behind typed structs so user code
does not import raw kernel values directly.

Constants are defined as literals rather than read from the platform
facade, so this module stays readable as the portable definition of
each option. The one exception is a compile-time-only import at the end
of this file, used solely to assert the literals match the values the
active backend reports through `boucle.socle.platform`.
"""


struct SocketType(TrivialRegisterPassable):
    """`SOCK_*` constants for use with `socket`."""

    comptime STREAM = Self(unsafe_id=1)    # SOCK_STREAM
    comptime DGRAM = Self(unsafe_id=2)     # SOCK_DGRAM
    comptime SEQPACKET = Self(unsafe_id=5) # SOCK_SEQPACKET
    comptime RAW = Self(unsafe_id=3)       # SOCK_RAW
    comptime RDM = Self(unsafe_id=4)       # SOCK_RDM

    var id: Int32

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_id: Int32):
        self.id = unsafe_id


struct SocketFlags(TrivialRegisterPassable, Defaultable):
    """`SOCK_*` constants for use with `socket`."""

    comptime NONBLOCK = Self(2048)    # O_NONBLOCK
    comptime CLOEXEC = Self(524288)   # O_CLOEXEC

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
        """Returns `self | rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self | rhs`.
        """
        return self.value | rhs.value


struct AddrFamily(TrivialRegisterPassable, Equatable):
    """`AF_*` constants for use with `socket`.

    Two families are equal when they carry the same `AF_*` id.
    """

    comptime UNSPEC = Self(unsafe_id=0)   # AF_UNSPEC
    comptime UNIX = Self(unsafe_id=1)     # AF_UNIX
    comptime INET = Self(unsafe_id=2)     # AF_INET
    comptime INET6 = Self(unsafe_id=10)   # AF_INET6
    comptime NETLINK = Self(unsafe_id=16) # AF_NETLINK

    var id: UInt16  # __kernel_sa_family_t

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_id: UInt16):
        self.id = unsafe_id

    @always_inline("nodebug")
    def __eq__(self, rhs: Self) -> Bool:
        """Return True when both carry the same AF_* id.

        Args:
            rhs: The family to compare against.

        Returns:
            True if the ids are equal.
        """
        return self.id == rhs.id

    @always_inline("nodebug")
    def __ne__(self, rhs: Self) -> Bool:
        """Return True when the AF_* ids differ.

        Args:
            rhs: The family to compare against.

        Returns:
            True if the ids differ.
        """
        return self.id != rhs.id

    @staticmethod
    def from_sockaddr(bytes: Span[UInt8, _]) -> Self:
        """Decode the family stored at the front of a sockaddr byte image.

        Every sockaddr the kernel writes starts with a host-order
        `sa_family_t`. This is the one place boucle reads it;
        `_getpeername`, `recv_from_v4` and `recv_from_v6` all go
        through here.

        Args:
            bytes: The sockaddr bytes as the kernel wrote them. Only the
                   first two are read.

        Returns:
            INET, INET6 or UNIX when the id is one of those; UNSPEC when
            fewer than two bytes are present or the id is any other
            family.
        """
        if len(bytes) < 2:
            return Self.UNSPEC
        var id = (
            bytes.unsafe_ptr().unsafe_bitcast[UInt16]().unsafe_load[alignment=1]()
        )
        if id == Self.INET.id or id == Self.INET6.id or id == Self.UNIX.id:
            return Self(unsafe_id=id)
        return Self.UNSPEC


struct Protocol(TrivialRegisterPassable, Defaultable):
    """`IPPROTO_*` and other constants for use with `socket`."""

    comptime IP = Self(unsafe_id=0)
    comptime ICMP = Self(unsafe_id=1)
    comptime IGMP = Self(unsafe_id=2)
    comptime IPIP = Self(unsafe_id=4)
    comptime TCP = Self(unsafe_id=6)
    comptime EGP = Self(unsafe_id=8)
    comptime PUP = Self(unsafe_id=12)
    comptime UDP = Self(unsafe_id=17)
    comptime IDP = Self(unsafe_id=22)
    comptime TP = Self(unsafe_id=29)
    comptime DCCP = Self(unsafe_id=33)
    comptime IPV6 = Self(unsafe_id=41)
    comptime RSVP = Self(unsafe_id=46)
    comptime GRE = Self(unsafe_id=47)
    comptime ESP = Self(unsafe_id=50)
    comptime AH = Self(unsafe_id=51)
    comptime MTP = Self(unsafe_id=92)
    comptime BEETPH = Self(unsafe_id=94)
    comptime ENCAP = Self(unsafe_id=98)
    comptime PIM = Self(unsafe_id=103)
    comptime COMP = Self(unsafe_id=108)
    comptime SCTP = Self(unsafe_id=132)
    comptime UDPLITE = Self(unsafe_id=136)
    comptime MPLS = Self(unsafe_id=137)
    comptime ETHERNET = Self(unsafe_id=143)
    comptime RAW = Self(unsafe_id=255)
    comptime MPTCP = Self(unsafe_id=262)
    comptime FRAGMENT = Self(unsafe_id=44)
    comptime ICMPV6 = Self(unsafe_id=58)
    comptime MH = Self(unsafe_id=135)
    comptime ROUTING = Self(unsafe_id=43)

    var id: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self = Self(unsafe_id=0)  # IPPROTO_IP

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_id: UInt32):
        self.id = unsafe_id


struct SendFlags(TrivialRegisterPassable, Defaultable):
    """`MSG_*` flags for use with `send`, `send_to`, and related functions."""

    comptime CONFIRM = Self(2048)      # MSG_CONFIRM
    comptime DONTROUTE = Self(4)       # MSG_DONTROUTE
    comptime DONTWAIT = Self(64)       # MSG_DONTWAIT
    comptime EOR = Self(128)           # MSG_EOR
    comptime MORE = Self(32768)        # MSG_MORE
    comptime NOSIGNAL = Self(16384)    # MSG_NOSIGNAL
    comptime OOB = Self(1)             # MSG_OOB

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
        """Returns `self | rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self | rhs`.
        """
        return self.value | rhs.value


struct RecvFlags(TrivialRegisterPassable, Defaultable):
    """`MSG_*` flags for use with `recv`, `recvfrom`, and related functions."""

    comptime CMSG_CLOEXEC = Self(1073741824) # MSG_CMSG_CLOEXEC
    comptime DONTWAIT = Self(64)             # MSG_DONTWAIT
    comptime ERRQUEUE = Self(8192)           # MSG_ERRQUEUE
    comptime OOB = Self(1)                   # MSG_OOB
    comptime PEEK = Self(2)                  # MSG_PEEK
    comptime TRUNC = Self(32)                # MSG_TRUNC
    comptime CTRUNC = Self(8)                # MSG_CTRUNC
    comptime WAITALL = Self(256)             # MSG_WAITALL

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
        """Returns `self | rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self | rhs`.
        """
        return self.value | rhs.value


struct Backlog(TrivialRegisterPassable):
    """Listen backlog values."""

    comptime DEFAULT = Self(128)

    var value: Int32

    @always_inline("nodebug")
    def __init__(out self, value: Int32):
        self.value = value


struct Shutdown(TrivialRegisterPassable, Equatable):
    """Direction for shutting down part or all of a connection.

    Maps to `SHUT_RD`, `SHUT_WR`, and `SHUT_RDWR` constants.
    """

    comptime RD = Self(0)     # SHUT_RD
    comptime WR = Self(1)     # SHUT_WR
    comptime RDWR = Self(2)   # SHUT_RDWR

    # Aliases matching the portable API naming convention.
    comptime READ = Self(0)
    comptime WRITE = Self(1)
    comptime BOTH = Self(2)

    var value: Int32

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: Int32):
        self.value = value

    @always_inline("nodebug")
    def __eq__(self, other: Self) -> Bool:
        """Returns True if both values represent the same shutdown direction."""
        return self.value == other.value

    @always_inline("nodebug")
    def __ne__(self, other: Self) -> Bool:
        """Returns True if the values represent different shutdown directions."""
        return self.value != other.value


# ── Compile-time platform value verification ─────────────────────────
# When a non-Linux platform arrives, mismatched values fire at compile
# time, forcing the constants to be updated.

from boucle.socle.platform import (
    AF_UNSPEC as _AF_UNSPEC,
    AF_UNIX as _AF_UNIX,
    AF_INET as _AF_INET,
    AF_INET6 as _AF_INET6,
    SOCK_STREAM as _SOCK_STREAM,
    SOCK_DGRAM as _SOCK_DGRAM,
    MSG_TRUNC as _MSG_TRUNC,
    MSG_CTRUNC as _MSG_CTRUNC,
)

def _verify_platform_values():
    """Assert hardcoded portable constants match the Linux backend values."""
    comptime assert AddrFamily.UNSPEC.id == UInt16(_AF_UNSPEC), "AF_UNSPEC mismatch"
    comptime assert AddrFamily.UNIX.id == UInt16(_AF_UNIX), "AF_UNIX mismatch"
    comptime assert AddrFamily.INET.id == UInt16(_AF_INET), "AF_INET mismatch"
    comptime assert AddrFamily.INET6.id == UInt16(_AF_INET6), "AF_INET6 mismatch"
    comptime assert SocketType.STREAM.id == Int32(_SOCK_STREAM), "SOCK_STREAM mismatch"
    comptime assert SocketType.DGRAM.id == Int32(_SOCK_DGRAM), "SOCK_DGRAM mismatch"
    comptime assert RecvFlags.TRUNC.value == UInt32(_MSG_TRUNC), "MSG_TRUNC mismatch"
    comptime assert RecvFlags.CTRUNC.value == UInt32(_MSG_CTRUNC), "MSG_CTRUNC mismatch"


comptime _VERIFIED_PLATFORM_VALUES: None = _verify_platform_values()
