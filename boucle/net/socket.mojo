"""A platform-agnostic, non-blocking socket.

Wraps an OwnedHandle and provides convenience constructors for common
socket configurations. All sockets are created with NONBLOCK and
CLOEXEC flags by default, with one exception: `tcp_connect` and
`udp_connect` deliberately return BLOCKING sockets, since their public
contract is "connect and hand back a usable blocking client." Set
non-blocking manually if you need to thread the result into a
CompletionLoop or ReadinessLoop.

Because the sockets are non-blocking, `Socket.connect` normally *starts* a
connect rather than completing it: it reports EINPROGRESS and the outcome is
collected later through a loop or `take_error`.

Every operation here raises `IOError` and nothing else, so one `except`
handles the whole surface.
"""

from std.memory import Pointer
from std.sys.info import size_of

from boucle.handle import RawHandle, OwnedHandle
from boucle.error import IOError
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
from boucle.socle.platform import (
    close as _fd_close,
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
    sockaddr_in,
    sockaddr_in6,
    socklen_t,
    AF_INET,
    AF_INET6,
    EAFNOSUPPORT,
    EBADF,
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


# ===----------------------------------------------------------------------=== #
# Private typed helpers — bridge portable option types to raw syscalls
#
# This is also boucle's error boundary: the socle layer reports failures as an
# Error whose text is a negated errno, and every helper below re-raises that as
# an `IOError`. Because the whole public Socket API is built on these helpers,
# it can declare `raises IOError` and callers get one error type to handle.
# ===----------------------------------------------------------------------=== #


@always_inline
def _own(fd: RawHandle) raises IOError -> OwnedHandle:
    """Take ownership of a file descriptor returned by a syscall.

    Args:
        fd: The descriptor to own.

    Returns:
        An OwnedHandle that closes `fd` on destruction.

    Raises:
        IOError wrapping EBADF if `fd` is negative.
    """
    try:
        return OwnedHandle(raw=fd)
    except:
        raise IOError.from_errno(EBADF)


@always_inline
def _sys_socket(
    domain: AddrFamily,
    type: SocketType,
    flags: SocketFlags,
    protocol: Protocol,
) raises IOError -> OwnedHandle:
    """Create a socket from typed options, returning an OwnedHandle.

    Args:
        domain: Address family.
        type: Socket type.
        flags: Creation flags (NONBLOCK, CLOEXEC).
        protocol: Transport protocol.

    Returns:
        An OwnedHandle owning the new socket.

    Raises:
        IOError on syscall failure.
    """
    var type_flags = type.id | Int32(flags.value)
    var fd: Int32
    try:
        fd = _socket(Int32(domain.id), type_flags, Int32(protocol.id))
    except e:
        raise IOError.from_error(e)
    return _own(fd)


@always_inline
def _sys_bind[
    Addr: SocketAddrStor
](ref handle: OwnedHandle, ref addr: Addr) raises IOError:
    """Bind a socket to a SocketAddrStor address.

    Args:
        handle: The socket to bind.
        addr: The address to bind to.

    Raises:
        IOError on syscall failure.
    """
    var stor = addr.addr_stor()
    var ptr = Pointer(to=stor).unsafe_bitcast[UInt8]()
    try:
        _bind(handle._raw, ptr, Int32(Addr.AddrStorType.ADDR_LEN))
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_listen(ref handle: OwnedHandle, backlog: Backlog) raises IOError:
    """Listen on a socket with typed Backlog.

    Args:
        handle: The socket to mark passive.
        backlog: Maximum pending connection queue length.

    Raises:
        IOError on syscall failure.
    """
    try:
        _listen(handle._raw, backlog.value)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_connect[
    Addr: SocketAddr
](ref handle: OwnedHandle, ref addr: Addr) raises IOError:
    """Connect a socket to a SocketAddr (storage variant).

    Args:
        handle: The socket to connect.
        addr: The peer address.

    Raises:
        IOError on syscall failure. On a non-blocking socket the connect is
        still running when the errno is EINPROGRESS.
    """
    var ptr = Pointer(to=addr).unsafe_bitcast[UInt8]()
    try:
        _connect(handle._raw, ptr, Int32(Addr.ADDR_LEN))
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_accept4(ref handle: OwnedHandle, flags: Int32) raises IOError -> Int32:
    """Accept a connection via accept4(2).

    Args:
        handle: The listening socket.
        flags: accept4 flags applied to the accepted socket.

    Returns:
        The accepted descriptor.

    Raises:
        IOError on syscall failure.
    """
    try:
        return _raw_accept4(handle._raw, flags)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_setsockopt(
    ref handle: OwnedHandle, level: Int32, optname: Int32, value: Int32
) raises IOError:
    """Set an integer socket option.

    Args:
        handle: The socket to configure.
        level: Protocol level (e.g. SOL_SOCKET).
        optname: Option name.
        value: Integer option value.

    Raises:
        IOError on syscall failure.
    """
    try:
        _setsockopt(handle._raw, level, optname, value)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_setsockopt_timeval(
    ref handle: OwnedHandle, level: Int32, optname: Int32, ms: UInt64
) raises IOError:
    """Set a `struct timeval` socket option from a millisecond count.

    Args:
        handle: The socket to configure.
        level: Protocol level (e.g. SOL_SOCKET).
        optname: Option name (SO_RCVTIMEO, SO_SNDTIMEO).
        ms: Timeout in milliseconds; 0 disables the timeout.

    Raises:
        IOError on syscall failure.
    """
    try:
        _setsockopt_timeval(handle._raw, level, optname, ms)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_getsockopt_int(
    ref handle: OwnedHandle, level: Int32, optname: Int32
) raises IOError -> Int32:
    """Read an integer socket option.

    Args:
        handle: The socket to query.
        level: Protocol level (e.g. SOL_SOCKET).
        optname: Option name.

    Returns:
        The option value.

    Raises:
        IOError on syscall failure.
    """
    try:
        return _getsockopt_int(handle._raw, level, optname)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_getfl(ref handle: OwnedHandle) raises IOError -> Int32:
    """Read the file status flags of a socket.

    Args:
        handle: The socket to query.

    Returns:
        The current `F_GETFL` flags.

    Raises:
        IOError on syscall failure.
    """
    try:
        return _fcntl_getfl(handle._raw)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_setfl(ref handle: OwnedHandle, flags: Int32) raises IOError:
    """Replace the file status flags of a socket.

    Args:
        handle: The socket to configure.
        flags: The new `F_SETFL` flags.

    Raises:
        IOError on syscall failure.
    """
    try:
        _fcntl_setfl(handle._raw, flags)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_shutdown(ref handle: OwnedHandle, how: Int32) raises IOError:
    """Shut down one or both directions of a connection.

    Args:
        handle: The socket to shut down.
        how: SHUT_RD, SHUT_WR, or SHUT_RDWR.

    Raises:
        IOError on syscall failure.
    """
    try:
        _shutdown(handle._raw, how)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_getsockname[
    addr_origin: MutOrigin, len_origin: MutOrigin
](
    ref handle: OwnedHandle,
    addr_ptr: Pointer[UInt8, addr_origin],
    len_ptr: Pointer[UInt8, len_origin],
) raises IOError:
    """Fill `addr_ptr` with the socket's local address.

    Args:
        handle: The socket to query.
        addr_ptr: Pointer to a sockaddr to fill.
        len_ptr: Pointer to the sockaddr length (in/out).

    Raises:
        IOError on syscall failure.
    """
    try:
        _raw_getsockname(handle._raw, addr_ptr, len_ptr)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_getpeername[
    addr_origin: MutOrigin, len_origin: MutOrigin
](
    fd: RawHandle,
    addr_ptr: Pointer[UInt8, addr_origin],
    len_ptr: Pointer[UInt8, len_origin],
) raises IOError:
    """Fill `addr_ptr` with the address of the connected peer.

    Args:
        fd: The connected socket.
        addr_ptr: Pointer to a sockaddr to fill.
        len_ptr: Pointer to the sockaddr length (in/out).

    Raises:
        IOError on syscall failure, e.g. ENOTCONN when not connected.
    """
    try:
        _raw_getpeername(fd, addr_ptr, len_ptr)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_close(fd: RawHandle) raises IOError:
    """Close a file descriptor.

    Args:
        fd: The descriptor to close.

    Raises:
        IOError on syscall failure.
    """
    try:
        _fd_close(unsafe_fd=fd)
    except e:
        raise IOError.from_error(e)


# ===----------------------------------------------------------------------=== #
# _getpeername — convenience wrapper around getpeername(2)
# ===----------------------------------------------------------------------=== #


def _getpeername(fd: RawHandle) raises IOError -> String:
    """Return the peer IP address of a connected socket as a string.

    Calls getpeername(2) on *fd* and parses the returned sockaddr into a
    human-readable IP string (e.g. ``"192.168.1.1"`` for IPv4 or
    ``"0:0:0:0:0:0:0:1"`` for IPv6).

    Returns:
        The peer's IP address in its textual form.

    Raises:
        IOError on syscall failure (e.g. ENOTCONN for an unconnected socket),
        or wrapping EAFNOSUPPORT when the peer's address family is neither
        IPv4 nor IPv6.
    """
    var stor = sockaddr_in6()
    var addrlen = socklen_t(size_of[sockaddr_in6]())
    var stor_p = Pointer(to=stor)
    var len_p = Pointer(to=addrlen)
    _sys_getpeername(
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
        raise IOError.from_errno(EAFNOSUPPORT)


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
    def tcp_v4() raises IOError -> Self:
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
    def tcp_v6() raises IOError -> Self:
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
    def udp_v4() raises IOError -> Self:
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
    def udp_v6() raises IOError -> Self:
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
    def tcp_listener_v6(
        port: UInt16, *, backlog: Int32 = 1024
    ) raises IOError -> Self:
        """Creates a dual-stack TCP listener bound to `[::]:port`.

        Sets `SO_REUSEADDR`, `SO_REUSEPORT`, and clears `IPV6_V6ONLY` so
        the listener accepts both IPv6 and IPv4-mapped connections.

        Args:
            port: The TCP port to bind to.
            backlog: Maximum pending connection queue length.

        Returns:
            A listening, non-blocking Socket.

        Raises:
            IOError on syscall failure.
        """
        var handle = _sys_socket(
            AddrFamily.INET6,
            SocketType.STREAM,
            SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
            Protocol.TCP,
        )
        _sys_setsockopt(
            handle, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), Int32(1)
        )
        _sys_setsockopt(
            handle, Int32(SOL_SOCKET), Int32(SO_REUSEPORT), Int32(1)
        )
        _sys_setsockopt(
            handle, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), Int32(0)
        )
        var addr = SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 0, port=port)
        _sys_bind(handle, addr)
        _sys_listen(handle, Backlog(backlog))
        return Self(handle^)

    @staticmethod
    def udp_listener_v6(port: UInt16) raises IOError -> Self:
        """Creates a dual-stack UDP listener bound to `[::]:port`.

        Sets `SO_REUSEADDR`, `SO_REUSEPORT`, and clears `IPV6_V6ONLY` so
        the socket receives both IPv6 and IPv4-mapped datagrams.

        Args:
            port: The UDP port to bind to.

        Returns:
            A bound, non-blocking Socket.

        Raises:
            IOError on syscall failure.
        """
        var handle = _sys_socket(
            AddrFamily.INET6,
            SocketType.DGRAM,
            SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
            Protocol.UDP,
        )
        _sys_setsockopt(
            handle, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), Int32(1)
        )
        _sys_setsockopt(
            handle, Int32(SOL_SOCKET), Int32(SO_REUSEPORT), Int32(1)
        )
        _sys_setsockopt(
            handle, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), Int32(0)
        )
        var addr = SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 0, port=port)
        _sys_bind(handle, addr)
        return Self(handle^)

    def bind[Addr: SocketAddrStor](self, ref addr: Addr) raises IOError:
        """Binds the socket to the given address.

        Args:
            addr: The local address to bind to.

        Raises:
            IOError on syscall failure (e.g. EADDRINUSE).
        """
        _sys_bind(self._handle, addr)

    def listen(self, backlog: Backlog) raises IOError:
        """Marks the socket as passive for accepting connections.

        Args:
            backlog: Maximum pending connection queue length.

        Raises:
            IOError on syscall failure.
        """
        _sys_listen(self._handle, backlog)

    def accept(self) raises IOError -> Self:
        """Accept a connection via accept4(2).

        Returns a new non-blocking, close-on-exec Socket for the
        accepted connection. Blocks on a blocking listening socket
        until a connection arrives.

        Returns:
            A Socket for the accepted connection.

        Raises:
            IOError on syscall failure. On a non-blocking listener with no
            pending connection the errno is EAGAIN.
        """
        var flags = Int32(O_NONBLOCK) | Int32(O_CLOEXEC)
        return Self(_own(_sys_accept4(self._handle, flags)))

    def set_reuse_addr(self, value: Bool = True) raises IOError:
        """Sets `SO_REUSEADDR` on the socket.

        Args:
            value: True to enable address reuse.

        Raises:
            IOError on syscall failure.
        """
        _sys_setsockopt(
            self._handle, Int32(SOL_SOCKET), Int32(SO_REUSEADDR),
            Int32(1) if value else Int32(0),
        )

    def set_reuse_port(self, value: Bool = True) raises IOError:
        """Sets `SO_REUSEPORT` on the socket.

        Args:
            value: True to enable port reuse.

        Raises:
            IOError on syscall failure.
        """
        _sys_setsockopt(
            self._handle, Int32(SOL_SOCKET), Int32(SO_REUSEPORT),
            Int32(1) if value else Int32(0),
        )

    def set_v6only(self, value: Bool) raises IOError:
        """Sets `IPV6_V6ONLY` on an IPv6 socket. `False` enables dual-stack.

        Args:
            value: True to restrict the socket to IPv6.

        Raises:
            IOError on syscall failure.
        """
        _sys_setsockopt(
            self._handle, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY),
            Int32(1) if value else Int32(0),
        )

    def set_recv_timeout(self, timeout_ms: UInt64) raises IOError:
        """Set receive timeout (SO_RCVTIMEO). 0 disables.

        Args:
            timeout_ms: Timeout in milliseconds; 0 disables the timeout.

        Raises:
            IOError on syscall failure.
        """
        _sys_setsockopt_timeval(
            self._handle, Int32(SOL_SOCKET), Int32(SO_RCVTIMEO), timeout_ms
        )

    def set_send_timeout(self, timeout_ms: UInt64) raises IOError:
        """Set send timeout (SO_SNDTIMEO). 0 disables.

        Args:
            timeout_ms: Timeout in milliseconds; 0 disables the timeout.

        Raises:
            IOError on syscall failure.
        """
        _sys_setsockopt_timeval(
            self._handle, Int32(SOL_SOCKET), Int32(SO_SNDTIMEO), timeout_ms
        )

    def set_blocking(self, blocking: Bool) raises IOError:
        """Toggle blocking mode. True = blocking, False = non-blocking.

        Args:
            blocking: True for blocking, False for non-blocking.

        Raises:
            IOError on syscall failure.
        """
        var flags = _sys_getfl(self._handle)
        if blocking:
            _sys_setfl(self._handle, flags & ~Int32(O_NONBLOCK))
        else:
            _sys_setfl(self._handle, flags | Int32(O_NONBLOCK))

    def take_error(self) raises IOError -> Optional[IOError]:
        """Read and clear the pending socket error (SO_ERROR).

        This is how the result of a non-blocking `connect` is collected:
        an empty Optional means the connect succeeded.

        Returns:
            The pending error, or an empty Optional when there is none.

        Raises:
            IOError if reading the option itself fails.
        """
        var val = _sys_getsockopt_int(
            self._handle, Int32(SOL_SOCKET), Int32(SO_ERROR)
        )
        if val == 0:
            return Optional[IOError]()
        return IOError.from_errno(Int(val))

    def connect[Addr: SocketAddrStor](self, ref addr: Addr) raises IOError:
        """Start `connect(2)` to the given address.

        Sockets from the `tcp_*`/`udp_*` factories are non-blocking, so this
        call normally *starts* the connect rather than completing it: it
        raises an IOError wrapping EINPROGRESS and the connection completes
        later. Observe that completion through a loop (readiness: wait for
        writability; completion: await the connect operation) and read the
        final status with `take_error`, or use `ConnectOutcome` for the
        decoded form. On a socket made blocking with `set_blocking(True)` the
        call instead blocks until the connect resolves.

        Args:
            addr: The peer address to connect to.

        Raises:
            IOError on syscall failure. EINPROGRESS means the connect is
            under way, not that it failed.
        """
        var stor = addr.addr_stor()
        _sys_connect(self._handle, stor)

    @staticmethod
    def _connect_new[Addr: SocketAddrStor](
        ref addr: Addr,
        family: AddrFamily,
        type: SocketType,
        protocol: Protocol,
    ) raises IOError -> Self:
        """Create a blocking socket, connect to `addr`, and return it.

        Args:
            addr: The peer address.
            family: Address family.
            type: Socket type.
            protocol: Transport protocol.

        Returns:
            A connected, blocking Socket.

        Raises:
            IOError on syscall failure.
        """
        var handle = _sys_socket(family, type, SocketFlags.CLOEXEC, protocol)
        var stor = addr.addr_stor()
        _sys_connect(handle, stor)
        return Self(handle^)

    @staticmethod
    def tcp_connect(ref addr: SocketAddrV4) raises IOError -> Self:
        """Blocking TCP client to an IPv4 address.

        Returns a BLOCKING socket suitable for direct blocking send/recv.
        Set non-blocking manually if you need to thread the result into a
        CompletionLoop or ReadinessLoop.
        """
        return Self._connect_new(addr, AddrFamily.INET, SocketType.STREAM, Protocol.TCP)

    @staticmethod
    def tcp_connect(ref addr: SocketAddrV6) raises IOError -> Self:
        """Blocking TCP client to an IPv6 address.

        Returns a BLOCKING socket suitable for direct blocking send/recv.
        Set non-blocking manually if you need to thread the result into a
        CompletionLoop or ReadinessLoop.
        """
        return Self._connect_new(addr, AddrFamily.INET6, SocketType.STREAM, Protocol.TCP)

    @staticmethod
    def udp_connect(ref addr: SocketAddrV4) raises IOError -> Self:
        """Blocking UDP client to an IPv4 address (sets default peer).

        Returns a BLOCKING socket suitable for direct blocking send/recv.
        Set non-blocking manually if you need to thread the result into a
        CompletionLoop or ReadinessLoop.
        """
        return Self._connect_new(addr, AddrFamily.INET, SocketType.DGRAM, Protocol.UDP)

    @staticmethod
    def udp_connect(ref addr: SocketAddrV6) raises IOError -> Self:
        """Blocking UDP client to an IPv6 address (sets default peer).

        Returns a BLOCKING socket suitable for direct blocking send/recv.
        Set non-blocking manually if you need to thread the result into a
        CompletionLoop or ReadinessLoop.
        """
        return Self._connect_new(addr, AddrFamily.INET6, SocketType.DGRAM, Protocol.UDP)

    def recv[
        origin: MutOrigin
    ](self, buf: Span[UInt8, origin]) raises IOError -> Int:
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
            self._handle._raw,
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(buf.unsafe_ptr())
            ),
            len(buf),
        )
        if n >= 0:
            return n
        raise IOError.from_errno(n)

    def send[
        origin: Origin
    ](self, buf: Span[UInt8, origin]) raises IOError -> Int:
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
            self._handle._raw,
            Pointer[UInt8, origin](
                unsafe_from_address=Int(buf.unsafe_ptr())
            ),
            len(buf),
        )
        if n >= 0:
            return n
        raise IOError.from_errno(n)

    def send_to[
        origin: Origin,
    ](self, buf: Span[UInt8, origin], ref addr: SocketAddrV4) raises IOError -> Int:
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
            IOError on syscall failure. On a non-blocking socket a full send
            buffer surfaces as EAGAIN / EWOULDBLOCK.
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
        raise IOError.from_errno(n)

    def recv_from[
        origin: MutOrigin,
    ](self, buf: Span[UInt8, origin]) raises IOError -> Tuple[Int, SocketAddrV4]:
        """Receive a datagram and the sender's address via recvfrom(2).

        Designed for unconnected UDP sockets. Returns a tuple of bytes
        read and the sender's SocketAddrV4 so the caller can reply to
        the correct peer.

        Args:
            buf: Mutable byte span to receive into.

        Returns:
            A tuple of (bytes_read, sender_address).

        Raises:
            IOError on syscall failure. On a non-blocking socket an empty
            receive queue surfaces as EAGAIN / EWOULDBLOCK.
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
            raise IOError.from_errno(n)
        var stor = SocketAddrStorV4()
        stor.addr = addr
        return (n, stor.to_v4())

    def shutdown(self, how: Shutdown) raises IOError:
        """Shut down read, write, or both directions.

        Args:
            how: Which direction(s) to shut down.

        Raises:
            IOError on syscall failure (e.g. ENOTCONN).
        """
        _sys_shutdown(self._handle, how.value)

    def local_addr_v4(self) raises IOError -> SocketAddrV4:
        """Return the local IPv4 address bound to this socket.

        Returns:
            The bound IPv4 address and port.

        Raises:
            IOError on syscall failure.
        """
        var addr = sockaddr_in()
        var addrlen = socklen_t(size_of[sockaddr_in]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        _sys_getsockname(
            self._handle,
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        var stor = SocketAddrStorV4()
        stor.addr = addr
        return stor.to_v4()

    def local_addr_v6(self) raises IOError -> SocketAddrV6:
        """Return the local IPv6 address bound to this socket.

        Returns:
            The bound IPv6 address and port.

        Raises:
            IOError on syscall failure.
        """
        var addr = sockaddr_in6()
        var addrlen = socklen_t(size_of[sockaddr_in6]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        _sys_getsockname(
            self._handle,
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        var stor = SocketAddrStorV6()
        stor.addr = addr
        return stor.to_v6()

    def peer_addr_v4(self) raises IOError -> SocketAddrV4:
        """Return the peer IPv4 address of a connected socket.

        Returns:
            The peer's IPv4 address and port.

        Raises:
            IOError on syscall failure (ENOTCONN when not connected).
        """
        var addr = sockaddr_in()
        var addrlen = socklen_t(size_of[sockaddr_in]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        _sys_getpeername(
            self._handle._raw,
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        var stor = SocketAddrStorV4()
        stor.addr = addr
        return stor.to_v4()

    def peer_addr_v6(self) raises IOError -> SocketAddrV6:
        """Return the peer IPv6 address of a connected socket.

        Returns:
            The peer's IPv6 address and port.

        Raises:
            IOError on syscall failure (ENOTCONN when not connected).
        """
        var addr = sockaddr_in6()
        var addrlen = socklen_t(size_of[sockaddr_in6]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        _sys_getpeername(
            self._handle._raw,
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        var stor = SocketAddrStorV6()
        stor.addr = addr
        return stor.to_v6()

    def close(mut self) raises IOError:
        """Explicitly close the socket.

        Idempotent -- safe to call before the destructor runs.

        Raises:
            IOError on syscall failure.
        """
        if self._handle._raw >= 0:
            _sys_close(self._handle._raw)
            self._handle._raw = -1

    @always_inline
    def raw(self) raises IOError -> RawHandle:
        """Returns the underlying raw handle value.

        Returns:
            The raw file descriptor.

        Raises:
            IOError wrapping EBADF if the stored handle is invalid (negative).
        """
        if self._handle._raw < 0:
            raise IOError.from_errno(EBADF)
        return self._handle._raw
