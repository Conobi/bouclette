"""Low-level socket syscall wrappers using libc external_call.

Uses external_call instead of raw syscall wrappers to work around
a Mojo 0.26.2 mojopkg deserialization crash when calling through
multiple internal subpackage layers.

All functions accept raw integer / pointer arguments only — no types
from ``boucle.*`` (outside ``boucle.socle``).  The typed-option
bridge lives in ``boucle.net.socket``.
"""

from std.ffi import external_call
from std.memory import Pointer

from boucle.socle.linux.raw import MSG_NOSIGNAL, F_GETFL, F_SETFL


@always_inline
def _socket(domain: Int32, type_flags: Int32, protocol: Int32) raises -> Int32:
    """Create a socket via socket(2).

    Args:
        domain: Address family (e.g. AF_INET, AF_INET6).
        type_flags: Socket type OR-ed with flags (e.g. SOCK_STREAM | SOCK_NONBLOCK).
        protocol: Protocol number (e.g. IPPROTO_TCP).

    Returns:
        The raw file descriptor on success.

    Raises:
        On syscall failure (negative return).
    """
    var res = external_call["socket", Int32](domain, type_flags, protocol)
    if res < 0:
        raise String(Int(res))
    return res


@always_inline
def _bind(
    fd: Int32,
    addr_ptr: Pointer[UInt8, ImmStaticOrigin],
    addr_len: Int32,
) raises:
    """Bind a socket to an address via bind(2).

    Args:
        fd: Socket file descriptor.
        addr_ptr: Pointer to the sockaddr structure.
        addr_len: Length of the sockaddr structure.

    Raises:
        On syscall failure.
    """
    var res = external_call["bind", Int32](fd, addr_ptr, addr_len)
    if res < 0:
        raise String(Int(res))


@always_inline
def _listen(fd: Int32, backlog: Int32) raises:
    """Mark a socket as passive via listen(2).

    Args:
        fd: Socket file descriptor.
        backlog: Maximum pending connection queue length.

    Raises:
        On syscall failure.
    """
    var res = external_call["listen", Int32](fd, backlog)
    if res < 0:
        raise String(Int(res))


@always_inline
def _setsockopt(
    fd: Int32,
    level: Int32,
    optname: Int32,
    value: Int32,
) raises:
    """Set a socket option via setsockopt(2).

    Args:
        fd: Socket file descriptor.
        level: Protocol level (e.g. SOL_SOCKET).
        optname: Option name (e.g. SO_REUSEADDR).
        value: Option value as a 32-bit integer.

    Raises:
        On syscall failure.
    """
    var val = value
    # Pre-capture the pointer in a named local — passing
    # Pointer(to=val) inline can clobber val's stack slot
    # during external_call arg marshaling.
    var val_p = Pointer(to=val)
    var res = external_call["setsockopt", Int32](
        fd,
        level,
        optname,
        val_p,
        UInt32(4),
    )
    if res < 0:
        raise String(Int(res))


@always_inline
def _connect(
    fd: Int32,
    addr_ptr: Pointer[UInt8, ImmStaticOrigin],
    addr_len: Int32,
) raises:
    """Connect a socket to an address via connect(2).

    Args:
        fd: Socket file descriptor.
        addr_ptr: Pointer to the sockaddr structure.
        addr_len: Length of the sockaddr structure.

    Raises:
        On syscall failure.
    """
    var res = external_call["connect", Int32](fd, addr_ptr, addr_len)
    if res < 0:
        raise String(Int(res))


@always_inline
def _recv(
    fd: Int32,
    buf: Pointer[UInt8, MutUntrackedOrigin],
    length: Int,
    flags: Int32 = Int32(0),
) -> Int:
    """Receive data from a socket via recv(2).

    Args:
        fd: Socket file descriptor.
        buf: Pointer to the receive buffer.
        length: Maximum number of bytes to receive.
        flags: recv flags (default 0).

    Returns:
        Bytes read, 0 on EOF, or negative on error (check errno).
    """
    return external_call["recv", Int](fd, buf, length, flags)


@always_inline
def _send(
    fd: Int32,
    buf: Pointer[UInt8, ImmStaticOrigin],
    length: Int,
    flags: Int32 = Int32(MSG_NOSIGNAL),
) -> Int:
    """Send data on a socket via send(2) with MSG_NOSIGNAL by default.

    Args:
        fd: Socket file descriptor.
        buf: Pointer to the data to send.
        length: Number of bytes to send.
        flags: send flags (default MSG_NOSIGNAL).

    Returns:
        Bytes sent or negative on error (check errno).
    """
    return external_call["send", Int](fd, buf, length, flags)


@always_inline
def _shutdown(fd: Int32, how: Int32) raises:
    """Shut down part of a full-duplex connection via shutdown(2).

    Args:
        fd: Socket file descriptor.
        how: Shutdown mode (0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR).

    Raises:
        On syscall failure.
    """
    var res = external_call["shutdown", Int32](fd, how)
    if res < 0:
        raise String(Int(res))


@always_inline
def _getsockopt_int(fd: Int32, level: Int32, optname: Int32) raises -> Int32:
    """Get an integer-valued socket option via getsockopt(2).

    Args:
        fd: Socket file descriptor.
        level: Protocol level (e.g. SOL_SOCKET).
        optname: Option name (e.g. SO_ERROR).

    Returns:
        The option value as a 32-bit integer.

    Raises:
        On syscall failure.
    """
    var val = Int32(0)
    var optlen = UInt32(4)
    var val_p = Pointer(to=val)
    var len_p = Pointer(to=optlen)
    var res = external_call["getsockopt", Int32](fd, level, optname, val_p, len_p)
    if res < 0:
        raise String(Int(res))
    return val


@always_inline
def _setsockopt_timeval(
    fd: Int32,
    level: Int32,
    optname: Int32,
    ms: UInt64,
) raises:
    """Set a timeval socket option via setsockopt(2) (SO_RCVTIMEO / SO_SNDTIMEO).

    Args:
        fd: Socket file descriptor.
        level: Protocol level (e.g. SOL_SOCKET).
        optname: Option name (e.g. SO_RCVTIMEO).
        ms: Timeout in milliseconds. 0 disables the timeout.

    Raises:
        On syscall failure.
    """
    var tv = InlineArray[Int64, 2](fill=Int64(0))
    tv[0] = Int64(ms // 1000)
    tv[1] = Int64((ms % 1000) * 1000)
    var tv_p = Pointer(to=tv)
    var res = external_call["setsockopt", Int32](
        fd, level, optname, tv_p, UInt32(16),
    )
    if res < 0:
        raise String(Int(res))


@always_inline
def _fcntl_getfl(fd: Int32) raises -> Int32:
    """Get file descriptor flags via fcntl(fd, F_GETFL).

    Args:
        fd: File descriptor.

    Returns:
        Current fd flags.

    Raises:
        On syscall failure.
    """
    var res = external_call["fcntl", Int32](fd, Int32(F_GETFL), Int32(0))
    if res < 0:
        raise String(Int(res))
    return res


@always_inline
def _fcntl_setfl(fd: Int32, flags: Int32) raises:
    """Set file descriptor flags via fcntl(fd, F_SETFL, flags).

    Args:
        fd: File descriptor.
        flags: Flags to set.

    Raises:
        On syscall failure.
    """
    var res = external_call["fcntl", Int32](fd, Int32(F_SETFL), flags)
    if res < 0:
        raise String(Int(res))
