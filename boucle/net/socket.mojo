"""A platform-agnostic, non-blocking socket.

Wraps an OwnedHandle and provides convenience constructors for common
socket configurations. All sockets are created with NONBLOCK and
CLOEXEC flags by default, with one exception: `tcp_connect` and
`udp_connect` deliberately return BLOCKING sockets, since their public
contract is "connect and hand back a usable blocking client." Set
non-blocking manually if you need to thread the result into a
CompletionLoop or ReadinessLoop.
"""

from std.memory import Pointer
from std.sys.info import size_of

from boucle.handle import RawHandle, OwnedHandle
from boucle.error import IOError
from boucle.socle.linux.fd import close as _fd_close
from boucle.net.addr import (
    SocketAddr, SocketAddrStor, SocketAddrV4, SocketAddrV6,
    SocketAddrStorV4, SocketAddrStorV6,
)
from boucle.net.ip import IpAddrV4, IpAddrV6
from boucle.net.options import (
    AddrFamily,
    SocketType,
    SocketFlags,
    Protocol,
    Backlog,
    Shutdown,
)
from boucle.socle.linux.net.syscalls import (
    _socket,
    _bind,
    _listen,
    _raw_accept4,
    _setsockopt,
    _connect,
    _recv,
    _send,
    _sendto as _raw_sendto,
    _recvfrom as _raw_recvfrom,
    _shutdown,
    _setsockopt_timeval,
    _fcntl_getfl,
    _fcntl_setfl,
    _getsockopt_int,
    _getsockname as _raw_getsockname,
    _getpeername as _raw_getpeername,
)
from boucle.socle.linux.errno import _check_for_errors, Errno
from boucle.socle.linux.raw import (
    sockaddr_in,
    sockaddr_in6,
    socklen_t,
    AF_INET,
    AF_INET6,
    SOL_SOCKET,
    SO_REUSEADDR,
    SO_REUSEPORT,
    SO_RCVTIMEO,
    SO_SNDTIMEO,
    SO_ERROR,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    O_NONBLOCK,
    O_CLOEXEC,
    MSG_NOSIGNAL,
)
from boucle.socle.linux.raw.utils import _to_be


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
    var ptr = Pointer(to=stor).unsafe_bitcast[UInt8]()
    var fd = handle.raw()
    _bind(fd, ptr, Int32(Addr.AddrStorType.ADDR_LEN))


@always_inline
def _sys_listen(ref handle: OwnedHandle, backlog: Backlog) raises:
    """Listen on a socket with typed Backlog."""
    _listen(handle.raw(), backlog.value)


@always_inline
def _sys_connect[Addr: SocketAddr](ref handle: OwnedHandle, ref addr: Addr) raises:
    """Connect a socket to a SocketAddr (storage variant)."""
    var ptr = Pointer(to=addr).unsafe_bitcast[UInt8]()
    var fd = handle.raw()
    _connect(fd, ptr, Int32(Addr.ADDR_LEN))


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
    var stor = sockaddr_in6()
    var addrlen = socklen_t(size_of[sockaddr_in6]())
    var stor_p = Pointer(to=stor)
    var len_p = Pointer(to=addrlen)
    _raw_getpeername(
        fd,
        stor_p.unsafe_bitcast[UInt8](),
        len_p.unsafe_bitcast[UInt8](),
    )
    var family = Int(stor.sin6_family)
    if family == AF_INET:
        # IPv4: address bytes sit at offset 4 in sockaddr_in
        # (2-byte family + 2-byte port).
        var bp = stor_p.unsafe_bitcast[UInt8]().unsafe_offset(4)
        return String(
            Int(bp[unsafe_offset=0]), ".", Int(bp[unsafe_offset=1]), ".",
            Int(bp[unsafe_offset=2]), ".", Int(bp[unsafe_offset=3]),
        )
    elif family == AF_INET6:
        # IPv6: 16 address bytes start at offset 8 in sockaddr_in6
        # (2-byte family + 2-byte port + 4-byte flowinfo).
        # Each pair of network-order bytes forms one host-order UInt16 segment.
        var bp = stor_p.unsafe_bitcast[UInt8]().unsafe_offset(8)
        var ip = IpAddrV6(
            UInt16(Int(bp[unsafe_offset=0]) * 256 + Int(bp[unsafe_offset=1])),
            UInt16(Int(bp[unsafe_offset=2]) * 256 + Int(bp[unsafe_offset=3])),
            UInt16(Int(bp[unsafe_offset=4]) * 256 + Int(bp[unsafe_offset=5])),
            UInt16(Int(bp[unsafe_offset=6]) * 256 + Int(bp[unsafe_offset=7])),
            UInt16(Int(bp[unsafe_offset=8]) * 256 + Int(bp[unsafe_offset=9])),
            UInt16(Int(bp[unsafe_offset=10]) * 256 + Int(bp[unsafe_offset=11])),
            UInt16(Int(bp[unsafe_offset=12]) * 256 + Int(bp[unsafe_offset=13])),
            UInt16(Int(bp[unsafe_offset=14]) * 256 + Int(bp[unsafe_offset=15])),
        )
        return String(ip)
    else:
        raise t"unsupported address family: {Int(family)}"


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
    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source Socket to move from.
        """
        self._handle = move._handle^

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

    def accept(self) raises -> Self:
        """Accept a connection via accept4(2).

        Returns a new non-blocking, close-on-exec Socket for the
        accepted connection. Blocks on a blocking listening socket
        until a connection arrives.
        """
        var flags = Int32(O_NONBLOCK) | Int32(O_CLOEXEC)
        var fd = _raw_accept4(self._handle.raw(), flags)
        return Self(OwnedHandle(raw=fd))

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

    def set_recv_timeout(self, ms: UInt64) raises:
        """Set receive timeout (SO_RCVTIMEO). ms=0 disables."""
        _setsockopt_timeval(self._handle._raw, Int32(SOL_SOCKET), Int32(SO_RCVTIMEO), ms)

    def set_send_timeout(self, ms: UInt64) raises:
        """Set send timeout (SO_SNDTIMEO). ms=0 disables."""
        _setsockopt_timeval(self._handle._raw, Int32(SOL_SOCKET), Int32(SO_SNDTIMEO), ms)

    def set_blocking(self, blocking: Bool) raises:
        """Toggle blocking mode. True = blocking, False = non-blocking."""
        var flags = _fcntl_getfl(self._handle._raw)
        if blocking:
            _fcntl_setfl(self._handle._raw, flags & ~Int32(O_NONBLOCK))
        else:
            _fcntl_setfl(self._handle._raw, flags | Int32(O_NONBLOCK))

    def take_error(self) raises -> Optional[IOError]:
        """Read and clear the pending socket error (SO_ERROR)."""
        var val = _getsockopt_int(self._handle._raw, Int32(SOL_SOCKET), Int32(SO_ERROR))
        if val == 0:
            return Optional[IOError]()
        return IOError(Errno(errno=UInt16(val)))

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

    def recv[origin: MutOrigin](self, buf: Span[UInt8, origin]) raises -> Int:
        """Receive into buf. Returns bytes read (0 = peer closed).

        On a blocking socket the call blocks until data arrives or the
        peer closes the connection.  On a non-blocking socket it returns
        immediately; if no data is available the raised ``IOError`` wraps
        ``EAGAIN`` / ``EWOULDBLOCK``.

        Args:
            buf: Mutable byte span to receive into.

        Returns:
            Number of bytes read, or 0 when the peer has closed.

        Raises:
            IOError on syscall failure.
        """
        var n = _recv(
            self.raw(),
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(buf.unsafe_ptr())
            ),
            len(buf),
        )
        if n >= 0:
            return n
        raise String(n)

    def send[origin: Origin](self, buf: Span[UInt8, origin]) raises -> Int:
        """Send from buf. Returns bytes written (may be partial).

        ``MSG_NOSIGNAL`` is applied internally to suppress ``SIGPIPE`` on
        Linux so callers never need to install a signal handler.

        On a blocking socket the call blocks until the kernel accepts at
        least some bytes.  On a non-blocking socket it returns
        immediately; if the send buffer is full the raised ``IOError``
        wraps ``EAGAIN`` / ``EWOULDBLOCK``.

        Args:
            buf: Byte span to send.

        Returns:
            Number of bytes actually written (may be less than ``len(buf)``).

        Raises:
            IOError on syscall failure.
        """
        var n = _send(
            self.raw(),
            Pointer[UInt8, origin](
                unsafe_from_address=Int(buf.unsafe_ptr())
            ),
            len(buf),
        )
        if n >= 0:
            return n
        raise String(n)

    def send_to[
        origin: Origin,
    ](self, buf: Span[UInt8, origin], ref addr: SocketAddrV4) raises -> Int:
        """Send a datagram to `addr` via sendto(2).

        Uses ``MSG_NOSIGNAL`` internally to suppress ``SIGPIPE`` on Linux.
        Designed for unconnected UDP sockets — the destination address is
        specified per-call rather than via a prior ``connect(2)``.

        Args:
            buf: Byte span to send.
            addr: IPv4 destination address (ip + port).

        Returns:
            Number of bytes actually sent.

        Raises:
            On syscall failure.
        """
        var stor = addr.addr_stor()
        var stor_p = Pointer(to=stor.addr)
        var fd = self._handle._raw
        var buf_ptr = Pointer[UInt8, origin](
            unsafe_from_address=Int(buf.unsafe_ptr())
        )
        var n = _raw_sendto(
            fd,
            buf_ptr,
            len(buf),
            Int32(MSG_NOSIGNAL),
            stor_p.unsafe_bitcast[UInt8](),
            UInt(size_of[sockaddr_in]()),
        )
        if n >= 0:
            return n
        raise String(n)

    def recv_from[
        origin: MutOrigin,
    ](self, buf: Span[UInt8, origin]) raises -> Tuple[Int, SocketAddrV4]:
        """Receive a datagram and the sender's address via recvfrom(2).

        Designed for unconnected UDP sockets. Returns a tuple of bytes
        read and the sender's SocketAddrV4 so the caller can reply to
        the correct peer.

        Args:
            buf: Mutable byte span to receive into.

        Returns:
            A tuple of (bytes_read, sender_address).

        Raises:
            On syscall failure.
        """
        var addr = sockaddr_in()
        var addrlen = socklen_t(size_of[sockaddr_in]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        var fd = self._handle._raw
        var n = _raw_recvfrom(
            fd,
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(buf.unsafe_ptr())
            ),
            len(buf),
            Int32(0),
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        if n < 0:
            raise String(n)
        var stor = SocketAddrStorV4()
        stor.addr = addr
        return (n, stor.to_v4())

    def shutdown(self, how: Shutdown) raises:
        """Shut down read, write, or both directions."""
        _shutdown(self._handle._raw, how.value)

    def local_addr_v4(self) raises -> SocketAddrV4:
        """Return the local IPv4 address bound to this socket."""
        var addr = sockaddr_in()
        var addrlen = socklen_t(size_of[sockaddr_in]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        _raw_getsockname(
            self._handle._raw,
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        var stor = SocketAddrStorV4()
        stor.addr = addr
        return stor.to_v4()

    def local_addr_v6(self) raises -> SocketAddrV6:
        """Return the local IPv6 address bound to this socket."""
        var addr = sockaddr_in6()
        var addrlen = socklen_t(size_of[sockaddr_in6]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        _raw_getsockname(
            self._handle._raw,
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        var stor = SocketAddrStorV6()
        stor.addr = addr
        return stor.to_v6()

    def peer_addr_v4(self) raises -> SocketAddrV4:
        """Return the peer IPv4 address of a connected socket."""
        var addr = sockaddr_in()
        var addrlen = socklen_t(size_of[sockaddr_in]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        _raw_getpeername(
            self._handle._raw,
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        var stor = SocketAddrStorV4()
        stor.addr = addr
        return stor.to_v4()

    def peer_addr_v6(self) raises -> SocketAddrV6:
        """Return the peer IPv6 address of a connected socket."""
        var addr = sockaddr_in6()
        var addrlen = socklen_t(size_of[sockaddr_in6]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        _raw_getpeername(
            self._handle._raw,
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        var stor = SocketAddrStorV6()
        stor.addr = addr
        return stor.to_v6()

    def close(mut self) raises:
        """Explicitly close the socket. Idempotent -- safe to call before destructor."""
        if self._handle._raw >= 0:
            _fd_close(unsafe_fd=self._handle._raw)
            self._handle._raw = -1

    @always_inline
    def raw(self) raises -> RawHandle:
        """Returns the underlying raw handle value.

        Raises:
            If the stored handle is somehow invalid (negative).
        """
        return self._handle.raw()
