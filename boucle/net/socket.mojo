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
    EAFNOSUPPORT,
    EBADF,
    EINVAL,
    SOL_SOCKET,
    SOL_IP,
    SOL_IPV6,
    SOL_UDP,
    SO_REUSEADDR,
    SO_REUSEPORT,
    SO_RCVBUF,
    SO_SNDBUF,
    SO_RCVTIMEO,
    SO_SNDTIMEO,
    SO_ERROR,
    SO_TYPE,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    IP_RECVTOS,
    IP_TOS,
    IPV6_RECVTCLASS,
    IPV6_TCLASS,
    UDP_GRO,
    UDP_SEGMENT,
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
    """Take ownership of a syscall-returned fd; raises EBADF if negative."""
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
    """Create a socket from typed options, returning an OwnedHandle."""
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
    """Bind a socket to a `SocketAddrStor` address."""
    var stor = addr.addr_stor()
    var ptr = Pointer(to=stor).unsafe_bitcast[UInt8]()
    try:
        _bind(handle._raw, ptr, Int32(Addr.AddrStorType.ADDR_LEN))
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_listen(ref handle: OwnedHandle, backlog: Backlog) raises IOError:
    """Listen on a socket with typed `Backlog`."""
    try:
        _listen(handle._raw, backlog.value)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_connect[
    Addr: SocketAddr
](ref handle: OwnedHandle, ref addr: Addr) raises IOError:
    """Connect a socket to a `SocketAddr`.

    On a non-blocking socket the connect may still be running
    (EINPROGRESS).
    """
    var ptr = Pointer(to=addr).unsafe_bitcast[UInt8]()
    try:
        _connect(handle._raw, ptr, Int32(Addr.ADDR_LEN))
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_accept4(ref handle: OwnedHandle, flags: Int32) raises IOError -> Int32:
    """Accept a connection via `accept4(2)` with the given flags."""
    try:
        return _raw_accept4(handle._raw, flags)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_setsockopt(
    ref handle: OwnedHandle, level: Int32, optname: Int32, value: Int32
) raises IOError:
    """Set an integer socket option."""
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
        ms: Timeout in milliseconds; 0 disables the timeout.
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
def _buffer_size_arg(bytes: Int) raises IOError -> Int32:
    """Narrow a buffer size to the `int` setsockopt takes; EINVAL outside 0..Int32.MAX.

    The kernel reads a negative value as a huge unsigned one and clamps
    it to the sysctl cap instead of failing, so the range check has to
    happen here, before any syscall.
    """
    if bytes < 0 or bytes > Int(Int32.MAX):
        raise IOError(positive_errno=EINVAL)
    return Int32(bytes)


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
    """Replace the file status flags of a socket."""
    try:
        _fcntl_setfl(handle._raw, flags)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_shutdown(ref handle: OwnedHandle, how: Int32) raises IOError:
    """Shut down one or both directions of a connection."""
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
    """Fill `addr_ptr` with the socket's local address."""
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
    """Fill `addr_ptr` with the connected peer's address."""
    try:
        _raw_getpeername(fd, addr_ptr, len_ptr)
    except e:
        raise IOError.from_error(e)


@always_inline
def _sys_close(fd: RawHandle) raises IOError:
    """Close a file descriptor."""
    try:
        _fd_close(unsafe_fd=fd)
    except e:
        raise IOError.from_error(e)


# ===----------------------------------------------------------------------=== #
# _getpeername — convenience wrapper around getpeername(2)
# ===----------------------------------------------------------------------=== #


@always_inline
def _sockaddr_family(ref addr: sockaddr_in6, len: Int) -> AddrFamily:
    """Return the family a syscall wrote into a sockaddr_in6-sized image.

    Args:
        addr: The storage the kernel filled.
        len: The number of bytes the kernel reported as meaningful.

    Returns:
        The decoded family, or UNSPEC for a short or unknown image.
    """
    var bytes = Pointer(to=addr).unsafe_bitcast[UInt8]()
    return AddrFamily.from_sockaddr(Span(unsafe_ptr=bytes, length=len))


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
    var family = _sockaddr_family(stor, Int(addrlen))
    if family == AddrFamily.INET:
        # IPv4: address bytes sit at offset 4 in sockaddr_in
        # (2-byte family + 2-byte port).
        var bp = stor_p.unsafe_bitcast[UInt8]().unsafe_offset(4)
        return String(
            Int(bp[unsafe_offset=0]), ".", Int(bp[unsafe_offset=1]), ".",
            Int(bp[unsafe_offset=2]), ".", Int(bp[unsafe_offset=3]),
        )
    elif family == AddrFamily.INET6:
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
    """A platform-agnostic, non-blocking socket.

    `_type` is recorded at construction so the completion loop can tell
    a datagram socket from a stream without a syscall per operation.
    """

    var _handle: OwnedHandle
    var _type: SocketType

    def __init__(out self, var handle: OwnedHandle):
        """Adopt an existing descriptor, reading its type from `SO_TYPE`.

        A descriptor whose type cannot be read is treated as a stream:
        that is the safe default since datagram-only behaviours (asking
        for the full datagram length) are simply not requested.
        """
        self._handle = handle^
        self._type = SocketType.STREAM
        try:
            self._type = SocketType(
                unsafe_id=_getsockopt_int(
                    self._handle._raw, Int32(SOL_SOCKET), Int32(SO_TYPE)
                )
            )
        except:
            pass

    @always_inline
    def __init__(out self, var handle: OwnedHandle, *, type: SocketType):
        """Adopt a descriptor whose `SOCK_*` type the caller already knows."""
        self._handle = handle^
        self._type = type

    @always_inline
    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle^
        self._type = move._type

    @always_inline
    def is_datagram(self) -> Bool:
        """True for `SOCK_DGRAM`; False for stream or unreadable type."""
        return self._type == SocketType.DGRAM

    @staticmethod
    def tcp_v4() raises IOError -> Self:
        """Creates a non-blocking TCP IPv4 socket."""
        return Self(
            _sys_socket(
                AddrFamily.INET,
                SocketType.STREAM,
                SocketFlags.NONBLOCK | SocketFlags.CLOEXEC,
                Protocol.TCP,
            ),
            type=SocketType.STREAM,
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
            ),
            type=SocketType.STREAM,
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
            ),
            type=SocketType.DGRAM,
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
            ),
            type=SocketType.DGRAM,
        )

    @staticmethod
    def tcp_listener_v6(
        port: UInt16, *, backlog: Int32 = 1024
    ) raises IOError -> Self:
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
        return Self(handle^, type=SocketType.STREAM)

    @staticmethod
    def udp_listener_v6(port: UInt16) raises IOError -> Self:
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
        return Self(handle^, type=SocketType.DGRAM)

    def bind[Addr: SocketAddrStor](self, ref addr: Addr) raises IOError:
        """Bind the socket to the given address."""
        _sys_bind(self._handle, addr)

    def listen(self, backlog: Backlog) raises IOError:
        """Mark the socket as passive for accepting connections.
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
        return Self(
            _own(_sys_accept4(self._handle, flags)), type=SocketType.STREAM
        )

    def set_reuse_addr(self, value: Bool = True) raises IOError:
        """Set `SO_REUSEADDR` on the socket."""
        _sys_setsockopt(
            self._handle, Int32(SOL_SOCKET), Int32(SO_REUSEADDR),
            Int32(1) if value else Int32(0),
        )

    def set_reuse_port(self, value: Bool = True) raises IOError:
        """Set `SO_REUSEPORT` on the socket."""
        _sys_setsockopt(
            self._handle, Int32(SOL_SOCKET), Int32(SO_REUSEPORT),
            Int32(1) if value else Int32(0),
        )

    def set_v6only(self, value: Bool) raises IOError:
        """Set `IPV6_V6ONLY` on an IPv6 socket. `False` enables dual-stack."""
        _sys_setsockopt(
            self._handle, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY),
            Int32(1) if value else Int32(0),
        )

    def _family(self) raises IOError -> AddrFamily:
        """Return the socket's address family from `getsockname(2)`."""
        var addr = sockaddr_in6()
        var addrlen = socklen_t(size_of[sockaddr_in6]())
        var addr_p = Pointer(to=addr)
        var len_p = Pointer(to=addrlen)
        _sys_getsockname(
            self._handle,
            addr_p.unsafe_bitcast[UInt8](),
            len_p.unsafe_bitcast[UInt8](),
        )
        return _sockaddr_family(addr, Int(addrlen))

    def set_recv_tos(self, value: Bool = True) raises IOError:
        """Ask the kernel to attach the received TOS byte to each datagram.

        `IP_RECVTOS` on an AF_INET socket. On an AF_INET6 socket both
        `IPV6_RECVTCLASS` and `IP_RECVTOS`, so IPv4-mapped peers on a
        dual-stack socket also deliver a TOS record. The record lands in
        the control area of a `recv_msg` whose `Message` has
        `control_capacity` of at least 24
        (`Message.control_space(4)`); with `set_gro` also on, the kernel
        writes the TOS record before the GRO record, so 48 bytes hold
        both. `ControlMessages.ecn()` reads the codepoint. Raises
        EAFNOSUPPORT for non-IP sockets.
        """
        var on = Int32(1) if value else Int32(0)
        var family = self._family()
        if family == AddrFamily.INET6:
            _sys_setsockopt(
                self._handle, Int32(SOL_IPV6), Int32(IPV6_RECVTCLASS), on
            )
            _sys_setsockopt(self._handle, Int32(SOL_IP), Int32(IP_RECVTOS), on)
        elif family == AddrFamily.INET:
            _sys_setsockopt(self._handle, Int32(SOL_IP), Int32(IP_RECVTOS), on)
        else:
            raise IOError(positive_errno=EAFNOSUPPORT)

    def set_tos(self, value: UInt8) raises IOError:
        """Set the default TOS / traffic class for outgoing packets.

        `IP_TOS` on an AF_INET socket; `IPV6_TCLASS` and `IP_TOS` on an
        AF_INET6 socket so mapped destinations are covered. A per-message
        ECN mark (`Message.set_ecn`) overrides this for that datagram;
        when several TOS records are appended to one message the kernel
        applies the last.

        Args:
            value: Full TOS byte (DSCP in high 6 bits, ECN in low 2).
        """
        var tos = Int32(value)
        var family = self._family()
        if family == AddrFamily.INET6:
            _sys_setsockopt(
                self._handle, Int32(SOL_IPV6), Int32(IPV6_TCLASS), tos
            )
            _sys_setsockopt(self._handle, Int32(SOL_IP), Int32(IP_TOS), tos)
        elif family == AddrFamily.INET:
            _sys_setsockopt(self._handle, Int32(SOL_IP), Int32(IP_TOS), tos)
        else:
            raise IOError(positive_errno=EAFNOSUPPORT)

    def set_gro(self, value: Bool = True) raises IOError:
        """`SOL_UDP`/`UDP_GRO`: let the kernel coalesce consecutive datagrams from one peer into one receive.

        A coalesced receive carries a `SOL_UDP`/`UDP_GRO` control record
        holding the segment size as a 4-byte int, and may span up to 64
        segments (65535 bytes): a smaller receive buffer truncates the
        delivery. The kernel writes the TOS record before the GRO one, so
        a receiver that also asked for `set_recv_tos` needs 48 bytes of
        control capacity (two 24-byte records) or the GRO record is cut
        off (`control_truncated()`). The kernel answers ENOPROTOOPT on a
        non-UDP socket and EOPNOTSUPP on AF_UNIX.
        """
        _sys_setsockopt(
            self._handle, Int32(SOL_UDP), Int32(UDP_GRO),
            Int32(1) if value else Int32(0),
        )

    def set_gso_segment_size(self, size: UInt16) raises IOError:
        """`SOL_UDP`/`UDP_SEGMENT`: default segment size for sends on this socket.

        0 disables. A per-message `UDP_SEGMENT` control record overrides
        it for that datagram. The kernel answers ENOPROTOOPT on a non-UDP
        socket and EOPNOTSUPP on AF_UNIX.
        """
        _sys_setsockopt(
            self._handle, Int32(SOL_UDP), Int32(UDP_SEGMENT), Int32(Int(size))
        )

    def set_recv_buffer_size(self, bytes: Int) raises IOError:
        """`SO_RCVBUF`. The kernel doubles the value for bookkeeping and caps it at `net.core.rmem_max`.

        The kernel never fails on range; `bytes` outside 0..Int32.MAX
        raises EINVAL here before the syscall. Read `recv_buffer_size()`
        to learn the effective size.
        """
        _sys_setsockopt(
            self._handle, Int32(SOL_SOCKET), Int32(SO_RCVBUF),
            _buffer_size_arg(bytes),
        )

    def set_send_buffer_size(self, bytes: Int) raises IOError:
        """`SO_SNDBUF`. The kernel doubles the value for bookkeeping and caps it at `net.core.wmem_max`.

        The kernel never fails on range; `bytes` outside 0..Int32.MAX
        raises EINVAL here before the syscall. Read `send_buffer_size()`
        to learn the effective size.
        """
        _sys_setsockopt(
            self._handle, Int32(SOL_SOCKET), Int32(SO_SNDBUF),
            _buffer_size_arg(bytes),
        )

    def recv_buffer_size(self) raises IOError -> Int:
        """Kernel value of `SO_RCVBUF`, already doubled and capped."""
        return Int(
            _sys_getsockopt_int(
                self._handle, Int32(SOL_SOCKET), Int32(SO_RCVBUF)
            )
        )

    def send_buffer_size(self) raises IOError -> Int:
        """Kernel value of `SO_SNDBUF`, already doubled and capped."""
        return Int(
            _sys_getsockopt_int(
                self._handle, Int32(SOL_SOCKET), Int32(SO_SNDBUF)
            )
        )

    def set_recv_timeout(self, timeout_ms: UInt64) raises IOError:
        """Set receive timeout (`SO_RCVTIMEO`); 0 disables."""
        _sys_setsockopt_timeval(
            self._handle, Int32(SOL_SOCKET), Int32(SO_RCVTIMEO), timeout_ms
        )

    def set_send_timeout(self, timeout_ms: UInt64) raises IOError:
        """Set send timeout (`SO_SNDTIMEO`); 0 disables."""
        _sys_setsockopt_timeval(
            self._handle, Int32(SOL_SOCKET), Int32(SO_SNDTIMEO), timeout_ms
        )

    def set_blocking(self, blocking: Bool) raises IOError:
        """Toggle blocking mode. True = blocking, False = non-blocking."""
        var flags = _sys_getfl(self._handle)
        if blocking:
            _sys_setfl(self._handle, flags & ~Int32(O_NONBLOCK))
        else:
            _sys_setfl(self._handle, flags | Int32(O_NONBLOCK))

    def take_error(self) raises IOError -> Optional[IOError]:
        """Read and clear the pending socket error (`SO_ERROR`).

        This is how the result of a non-blocking `connect` is collected:
        an empty Optional means the connect succeeded.
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
        call normally raises EINPROGRESS and the connection completes later.
        Read the result with `take_error` or `ConnectOutcome`.
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
        return Self(handle^, type=type)

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

        Blocks on a blocking socket; raises EAGAIN on a non-blocking
        socket with no data available.
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

        `MSG_NOSIGNAL` applied internally; may return a short write.
        Blocks on a blocking socket; raises EAGAIN when the send buffer
        is full on a non-blocking socket.
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
        Addr: SocketAddrStor,
    ](self, buf: Span[UInt8, origin], ref addr: Addr) raises IOError -> Int:
        """Send a datagram to `addr` via sendto(2).

        For unconnected UDP sockets. `MSG_NOSIGNAL` applied internally.
        The address family of `addr` must match the socket's own family.
        """
        var stor = addr.addr_stor()
        var stor_p = Pointer(to=stor)
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
            UInt(Addr.AddrStorType.ADDR_LEN),
        )
        if n >= 0:
            return n
        raise IOError.from_errno(n)

    def _recv_from_any[
        origin: MutOrigin,
    ](self, buf: Span[UInt8, origin]) raises IOError -> Tuple[Int, sockaddr_in6]:
        """Receive a datagram and the raw sender address via recvfrom(2).

        The address is received into a `sockaddr_in6`-sized buffer, large
        enough for either family. The public `recv_from_v4`/`recv_from_v6`
        wrappers check the family the kernel wrote.
        """
        var addr = sockaddr_in6()
        var addrlen = socklen_t(size_of[sockaddr_in6]())
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
        return (n, addr)

    def recv_from_v4[
        origin: MutOrigin,
    ](self, buf: Span[UInt8, origin]) raises IOError -> Tuple[Int, SocketAddrV4]:
        """Receive a datagram and its IPv4 sender via `recvfrom(2)`.

        Raises EAFNOSUPPORT if the sender is not AF_INET.
        """
        var received = self._recv_from_any(buf)
        var raw = received[1]
        if _sockaddr_family(raw, size_of[sockaddr_in6]()) != AddrFamily.INET:
            raise IOError(positive_errno=EAFNOSUPPORT)
        var stor = SocketAddrStorV4()
        stor.addr = Pointer(to=raw).unsafe_bitcast[sockaddr_in]()[]
        return (received[0], stor.to_v4())

    def recv_from_v6[
        origin: MutOrigin,
    ](self, buf: Span[UInt8, origin]) raises IOError -> Tuple[Int, SocketAddrV6]:
        """Receive a datagram and its IPv6 sender via `recvfrom(2)`.

        Raises EAFNOSUPPORT if the sender is not AF_INET6.
        """
        var received = self._recv_from_any(buf)
        var raw = received[1]
        if _sockaddr_family(raw, size_of[sockaddr_in6]()) != AddrFamily.INET6:
            raise IOError(positive_errno=EAFNOSUPPORT)
        var stor = SocketAddrStorV6()
        stor.addr = raw
        return (received[0], stor.to_v6())

    def shutdown(self, how: Shutdown) raises IOError:
        """Shut down read, write, or both directions."""
        _sys_shutdown(self._handle, how.value)

    def local_addr_v4(self) raises IOError -> SocketAddrV4:
        """Return the local IPv4 address bound to this socket."""
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
        """Return the local IPv6 address bound to this socket."""
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
        """Return the peer IPv4 address of a connected socket."""
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
        """Return the peer IPv6 address of a connected socket."""
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
        """Explicitly close the socket. Idempotent."""
        if self._handle._raw >= 0:
            _sys_close(self._handle._raw)
            self._handle._raw = -1

    @always_inline
    def raw(self) raises IOError -> RawHandle:
        """Returns the underlying raw handle value.

        The returned handle is a plain value, not tied to this socket's
        lifetime or origin. If the call site is the socket's last use,
        Mojo's as-soon-as-possible destruction can drop (and close) the
        socket before the handle is actually used, e.g. before a syscall
        that consumes it runs. Callers that pass the handle on to a
        helper must keep the `Socket` alive for as long as the handle is
        in use, for example by taking `ref socket` into that helper
        rather than calling `socket.raw()` inline as an argument.

        Returns:
            The raw file descriptor.

        Raises:
            IOError wrapping EBADF if the stored handle is invalid (negative).
        """
        if self._handle._raw < 0:
            raise IOError.from_errno(EBADF)
        return self._handle._raw
