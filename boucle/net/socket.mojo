"""A platform-agnostic, non-blocking socket.

Wraps an OwnedHandle and provides convenience constructors for common
socket configurations. All sockets are created with NONBLOCK and
CLOEXEC flags by default, with one exception: `tcp_connect` and
`udp_connect` deliberately return BLOCKING sockets, since their public
contract is "connect and hand back a usable blocking client." Set
non-blocking manually if you need to thread the result into a
CompletionLoop or ReadinessLoop.
"""

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import size_of

from boucle.handle import RawHandle, OwnedHandle
from boucle.net.addr import SocketAddr, SocketAddrStor, SocketAddrV4, SocketAddrV6
from boucle.net.ip import IpAddrV6
from boucle.net.options import (
    AddrFamily,
    SocketType,
    SocketFlags,
    Protocol,
    Backlog,
)
from boucle.socle.linux.net.syscalls import (
    _socket,
    _bind,
    _listen,
    _setsockopt,
    _connect,
)
from boucle.socle.linux.raw import (
    sockaddr_in6,
    socklen_t,
    AF_INET,
    AF_INET6,
    SOL_SOCKET,
    SO_REUSEADDR,
    SO_REUSEPORT,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
)


# ===----------------------------------------------------------------------=== #
# Private typed helpers — bridge portable option types to raw syscalls
# ===----------------------------------------------------------------------=== #


@always_inline
def _sys_socket(
    domain: AddrFamily,
    type: SocketType,
    flags: SocketFlags,
    protocol: Protocol,
) raises -> OwnedHandle:
    """Create a socket from typed options, returning an OwnedHandle."""
    var type_flags = type.id | Int32(flags.value)
    return OwnedHandle(raw=_socket(Int32(domain.id), type_flags, Int32(protocol.id)))


@always_inline
def _sys_bind[Addr: SocketAddrStor](ref handle: OwnedHandle, ref addr: Addr) raises:
    """Bind a socket to a SocketAddrStor address."""
    var stor = addr.addr_stor()
    _bind(handle.raw(), stor.addr_unsafe_ptr(), Int32(Addr.AddrStorType.ADDR_LEN))


@always_inline
def _sys_listen(ref handle: OwnedHandle, backlog: Backlog) raises:
    """Listen on a socket with typed Backlog."""
    _listen(handle.raw(), backlog.value)


@always_inline
def _sys_connect[Addr: SocketAddr](ref handle: OwnedHandle, ref addr: Addr) raises:
    """Connect a socket to a SocketAddr (storage variant)."""
    _connect(handle.raw(), addr.addr_unsafe_ptr(), Int32(Addr.ADDR_LEN))


# ===----------------------------------------------------------------------=== #
# _getpeername — convenience wrapper around getpeername(2)
# ===----------------------------------------------------------------------=== #


def _getpeername(fd: RawHandle) raises -> String:
    """Return the peer IP address of a connected socket as a string.

    Calls getpeername(2) on *fd* and parses the returned sockaddr into a
    human-readable IP string (e.g. ``"192.168.1.1"`` for IPv4 or
    ``"0:0:0:0:0:0:0:1"`` for IPv6).

    Raises on syscall failure (e.g. ENOTCONN for an unconnected socket).
    """
    # sockaddr_in6 (28 bytes) is large enough for both IPv4 (16) and IPv6.
    var stor = sockaddr_in6()
    var addrlen = socklen_t(size_of[sockaddr_in6]())
    # Pre-capture pointers — passing UnsafePointer(to=x) inline can
    # clobber x's stack slot during external_call arg marshaling.
    var stor_p = UnsafePointer(to=stor)
    var len_p = UnsafePointer(to=addrlen)
    var res = external_call["getpeername", Int32](fd, stor_p, len_p)
    if res < 0:
        raise String(Int(res))
    var family = Int(stor.sin6_family)
    if family == AF_INET:
        # IPv4: address bytes sit at offset 4 in sockaddr_in
        # (2-byte family + 2-byte port).
        var bp = stor_p.bitcast[UInt8]() + 4
        return String(
            Int(bp[0]), ".", Int(bp[1]), ".",
            Int(bp[2]), ".", Int(bp[3]),
        )
    elif family == AF_INET6:
        # IPv6: 16 address bytes start at offset 8 in sockaddr_in6
        # (2-byte family + 2-byte port + 4-byte flowinfo).
        # Each pair of network-order bytes forms one host-order UInt16 segment.
        var bp = stor_p.bitcast[UInt8]() + 8
        var ip = IpAddrV6(
            UInt16(Int(bp[0]) * 256 + Int(bp[1])),
            UInt16(Int(bp[2]) * 256 + Int(bp[3])),
            UInt16(Int(bp[4]) * 256 + Int(bp[5])),
            UInt16(Int(bp[6]) * 256 + Int(bp[7])),
            UInt16(Int(bp[8]) * 256 + Int(bp[9])),
            UInt16(Int(bp[10]) * 256 + Int(bp[11])),
            UInt16(Int(bp[12]) * 256 + Int(bp[13])),
            UInt16(Int(bp[14]) * 256 + Int(bp[15])),
        )
        return String(ip)
    else:
        raise String("unsupported address family: ", Int(family))


# ===----------------------------------------------------------------------=== #
# Socket struct
# ===----------------------------------------------------------------------=== #


struct Socket(Movable):
    """A platform-agnostic, non-blocking socket."""

    var _handle: OwnedHandle

    @always_inline
    def __init__(out self, var handle: OwnedHandle):
        self._handle = handle^

    @always_inline
    def __init__(out self, *, deinit take: Self):
        """Move constructor.

        Args:
            take: The source Socket to move from.
        """
        self._handle = take._handle^

    @staticmethod
    def tcp_v4() raises -> Self:
        """Creates a non-blocking TCP IPv4 socket."""
        return Self(
            _sys_socket(
                AddrFamily.INET,
                SocketType.STREAM,
                SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
                Protocol.TCP,
            )
        )

    @staticmethod
    def tcp_v6() raises -> Self:
        """Creates a non-blocking TCP IPv6 socket."""
        return Self(
            _sys_socket(
                AddrFamily.INET6,
                SocketType.STREAM,
                SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
                Protocol.TCP,
            )
        )

    @staticmethod
    def udp_v4() raises -> Self:
        """Creates a non-blocking UDP IPv4 socket."""
        return Self(
            _sys_socket(
                AddrFamily.INET,
                SocketType.DGRAM,
                SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
                Protocol.UDP,
            )
        )

    @staticmethod
    def udp_v6() raises -> Self:
        """Creates a non-blocking UDP IPv6 socket."""
        return Self(
            _sys_socket(
                AddrFamily.INET6,
                SocketType.DGRAM,
                SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
                Protocol.UDP,
            )
        )

    @staticmethod
    def tcp_listener_v6(port: UInt16, *, backlog: Int32 = 1024) raises -> Self:
        """Creates a dual-stack TCP listener bound to `[::]:port`.

        Sets `SO_REUSEADDR`, `SO_REUSEPORT`, and clears `IPV6_V6ONLY` so
        the listener accepts both IPv6 and IPv4-mapped connections.
        """
        var handle = _sys_socket(
            AddrFamily.INET6,
            SocketType.STREAM,
            SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
            Protocol.TCP,
        )
        _setsockopt(handle.raw(), Int32(SOL_SOCKET), Int32(SO_REUSEADDR), Int32(1))
        _setsockopt(handle.raw(), Int32(SOL_SOCKET), Int32(SO_REUSEPORT), Int32(1))
        _setsockopt(handle.raw(), Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), Int32(0))
        var addr = SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 0, port=port)
        _sys_bind(handle, addr)
        _sys_listen(handle, Backlog(backlog))
        return Self(handle^)

    @staticmethod
    def udp_listener_v6(port: UInt16) raises -> Self:
        """Creates a dual-stack UDP listener bound to `[::]:port`.

        Sets `SO_REUSEADDR`, `SO_REUSEPORT`, and clears `IPV6_V6ONLY` so
        the socket receives both IPv6 and IPv4-mapped datagrams.
        """
        var handle = _sys_socket(
            AddrFamily.INET6,
            SocketType.DGRAM,
            SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
            Protocol.UDP,
        )
        _setsockopt(handle.raw(), Int32(SOL_SOCKET), Int32(SO_REUSEADDR), Int32(1))
        _setsockopt(handle.raw(), Int32(SOL_SOCKET), Int32(SO_REUSEPORT), Int32(1))
        _setsockopt(handle.raw(), Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), Int32(0))
        var addr = SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 0, port=port)
        _sys_bind(handle, addr)
        return Self(handle^)

    def bind[Addr: SocketAddrStor](self, ref addr: Addr) raises:
        """Binds the socket to the given address."""
        _sys_bind(self._handle, addr)

    def listen(self, backlog: Backlog) raises:
        """Marks the socket as passive for accepting connections."""
        _sys_listen(self._handle, backlog)

    def set_reuse_addr(self, value: Bool = True) raises:
        """Sets `SO_REUSEADDR` on the socket."""
        _setsockopt(
            self._handle.raw(), Int32(SOL_SOCKET), Int32(SO_REUSEADDR),
            Int32(1) if value else Int32(0),
        )

    def set_reuse_port(self, value: Bool = True) raises:
        """Sets `SO_REUSEPORT` on the socket."""
        _setsockopt(
            self._handle.raw(), Int32(SOL_SOCKET), Int32(SO_REUSEPORT),
            Int32(1) if value else Int32(0),
        )

    def set_v6only(self, value: Bool) raises:
        """Sets `IPV6_V6ONLY` on an IPv6 socket. `False` enables dual-stack."""
        _setsockopt(
            self._handle.raw(), Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY),
            Int32(1) if value else Int32(0),
        )

    def connect[Addr: SocketAddrStor](self, ref addr: Addr) raises:
        """Blocking `connect(2)` to the given address."""
        var stor = addr.addr_stor()
        _sys_connect(self._handle, stor)

    @staticmethod
    def _connect_new[Addr: SocketAddrStor](
        ref addr: Addr,
        family: AddrFamily,
        type: SocketType,
        protocol: Protocol,
    ) raises -> Self:
        """Create a blocking socket, connect to `addr`, and return it."""
        var handle = _sys_socket(family, type, SocketFlags.CLOEXEC, protocol)
        var stor = addr.addr_stor()
        _sys_connect(handle, stor)
        return Self(handle^)

    @staticmethod
    def tcp_connect(ref addr: SocketAddrV4) raises -> Self:
        """Blocking TCP client to an IPv4 address.

        Returns a BLOCKING socket suitable for direct blocking send/recv.
        Set non-blocking manually if you need to thread the result into a
        CompletionLoop or ReadinessLoop.
        """
        return Self._connect_new(addr, AddrFamily.INET, SocketType.STREAM, Protocol.TCP)

    @staticmethod
    def tcp_connect(ref addr: SocketAddrV6) raises -> Self:
        """Blocking TCP client to an IPv6 address.

        Returns a BLOCKING socket suitable for direct blocking send/recv.
        Set non-blocking manually if you need to thread the result into a
        CompletionLoop or ReadinessLoop.
        """
        return Self._connect_new(addr, AddrFamily.INET6, SocketType.STREAM, Protocol.TCP)

    @staticmethod
    def udp_connect(ref addr: SocketAddrV4) raises -> Self:
        """Blocking UDP client to an IPv4 address (sets default peer).

        Returns a BLOCKING socket suitable for direct blocking send/recv.
        Set non-blocking manually if you need to thread the result into a
        CompletionLoop or ReadinessLoop.
        """
        return Self._connect_new(addr, AddrFamily.INET, SocketType.DGRAM, Protocol.UDP)

    @staticmethod
    def udp_connect(ref addr: SocketAddrV6) raises -> Self:
        """Blocking UDP client to an IPv6 address (sets default peer).

        Returns a BLOCKING socket suitable for direct blocking send/recv.
        Set non-blocking manually if you need to thread the result into a
        CompletionLoop or ReadinessLoop.
        """
        return Self._connect_new(addr, AddrFamily.INET6, SocketType.DGRAM, Protocol.UDP)

    @always_inline
    def raw(self) raises -> RawHandle:
        """Returns the underlying raw handle value.

        Raises:
            If the stored handle is somehow invalid (negative).
        """
        return self._handle.raw()
