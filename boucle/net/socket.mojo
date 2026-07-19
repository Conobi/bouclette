"""A platform-agnostic, non-blocking socket.

Wraps an OwnedHandle and provides convenience constructors for common
socket configurations. All sockets are created with NONBLOCK and
CLOEXEC flags by default, with one exception: `tcp_connect` and
`udp_connect` deliberately return BLOCKING sockets, since their public
contract is "connect and hand back a usable blocking client." Set
non-blocking manually if you need to thread the result into a
CompletionLoop or ReadinessLoop.
"""

from boucle.handle import RawHandle, OwnedHandle
from boucle.net.addr import SocketAddrStor, SocketAddrV4, SocketAddrV6
from boucle.net.options import (
    AddrFamily,
    SocketType,
    SocketFlags,
    Protocol,
    Backlog,
)
from boucle._sys.linux.net.socket import (
    socket as _sys_socket,
    bind as _sys_bind,
    listen as _sys_listen,
)
from boucle._sys.linux.net.syscalls import _setsockopt, _connect
from boucle._sys.linux.raw import (
    SOL_SOCKET,
    SO_REUSEADDR,
    SO_REUSEPORT,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
)


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
        _setsockopt(handle, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), Int32(1))
        _setsockopt(handle, Int32(SOL_SOCKET), Int32(SO_REUSEPORT), Int32(1))
        _setsockopt(handle, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), Int32(0))
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
        _setsockopt(handle, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), Int32(1))
        _setsockopt(handle, Int32(SOL_SOCKET), Int32(SO_REUSEPORT), Int32(1))
        _setsockopt(handle, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), Int32(0))
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
            self._handle, Int32(SOL_SOCKET), Int32(SO_REUSEADDR),
            Int32(1) if value else Int32(0),
        )

    def set_reuse_port(self, value: Bool = True) raises:
        """Sets `SO_REUSEPORT` on the socket."""
        _setsockopt(
            self._handle, Int32(SOL_SOCKET), Int32(SO_REUSEPORT),
            Int32(1) if value else Int32(0),
        )

    def set_v6only(self, value: Bool) raises:
        """Sets `IPV6_V6ONLY` on an IPv6 socket. `False` enables dual-stack."""
        _setsockopt(
            self._handle, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY),
            Int32(1) if value else Int32(0),
        )

    def connect[Addr: SocketAddrStor](self, ref addr: Addr) raises:
        """Blocking `connect(2)` to the given address."""
        var stor = addr.addr_stor()
        _connect(self._handle, stor)

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
        _connect(handle, stor)
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
