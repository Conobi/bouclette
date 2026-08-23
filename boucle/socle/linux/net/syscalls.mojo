"""Low-level socket syscall wrappers using raw Linux syscalls.

Uses inline-assembly syscall wrappers instead of libc external_call.
Error handling follows the raw-syscall pattern: the kernel returns the
negated errno directly in the return register, decoded via
``_check_for_errors`` / ``unsafe_decode_result``.

All functions accept raw integer / pointer arguments only — no types
from ``boucle.*`` (outside ``boucle.socle``).  The typed-option
bridge lives in ``boucle.net.socket``.
"""

from std.memory import Pointer

from boucle.socle.linux.raw import (
    syscall,
    MSG_NOSIGNAL,
    F_GETFL,
    F_SETFL,
    socklen_t,
    __NR_socket,
    __NR_bind,
    __NR_listen,
    __NR_setsockopt,
    __NR_connect,
    __NR_recvfrom,
    __NR_sendto,
    __NR_shutdown,
    __NR_getsockopt,
    __NR_getsockname,
    __NR_getpeername,
    __NR_fcntl,
)
from boucle.socle.linux.errno import _check_for_errors, unsafe_decode_result
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.ptr import null_ptr


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
        On syscall failure.
    """
    var res = syscall[__NR_socket, Scalar[DType.int64]](domain, type_flags, protocol)
    return unsafe_decode_result[DType.int32](res)


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
    var res = syscall[__NR_bind, Scalar[DType.int64]](fd, addr_ptr, addr_len)
    _check_for_errors(res)


@always_inline
def _listen(fd: Int32, backlog: Int32) raises:
    """Mark a socket as passive via listen(2).

    Args:
        fd: Socket file descriptor.
        backlog: Maximum pending connection queue length.

    Raises:
        On syscall failure.
    """
    var res = syscall[__NR_listen, Scalar[DType.int64]](fd, backlog)
    _check_for_errors(res)


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
    var val_p = Pointer(to=val)
    var res = syscall[__NR_setsockopt, Scalar[DType.int64]](
        fd,
        level,
        optname,
        val_p,
        UInt(4),
    )
    _check_for_errors(res)


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
    var res = syscall[__NR_connect, Scalar[DType.int64]](fd, addr_ptr, addr_len)
    _check_for_errors(res)


@always_inline
def _recv(
    fd: Int32,
    buf: Pointer[UInt8, MutUntrackedOrigin],
    length: Int,
    flags: Int32 = Int32(0),
) -> Int:
    """Receive data from a socket via recvfrom(2) with NULL src_addr.

    Args:
        fd: Socket file descriptor.
        buf: Pointer to the receive buffer.
        length: Maximum number of bytes to receive.
        flags: recv flags (default 0).

    Returns:
        Bytes read, 0 on EOF, or negated errno on error.
    """
    var null_addr = null_ptr[c_void, ImmStaticOrigin]()
    var null_len = null_ptr[c_void, ImmStaticOrigin]()
    return Int(
        syscall[__NR_recvfrom, Scalar[DType.int64]](
            fd, buf, UInt(length), UInt(flags), null_addr, null_len
        )
    )


@always_inline
def _send(
    fd: Int32,
    buf: Pointer[UInt8, ImmStaticOrigin],
    length: Int,
    flags: Int32 = Int32(MSG_NOSIGNAL),
) -> Int:
    """Send data on a socket via sendto(2) with NULL dest_addr.

    MSG_NOSIGNAL is applied by default.

    Args:
        fd: Socket file descriptor.
        buf: Pointer to the data to send.
        length: Number of bytes to send.
        flags: send flags (default MSG_NOSIGNAL).

    Returns:
        Bytes sent or negated errno on error.
    """
    var null_addr = null_ptr[c_void, ImmStaticOrigin]()
    return Int(
        syscall[__NR_sendto, Scalar[DType.int64]](
            fd, buf, UInt(length), UInt(flags), null_addr, UInt(0)
        )
    )


@always_inline
def _sendto[
    buf_origin: Origin,
    addr_origin: Origin,
](
    fd: Int32,
    buf: Pointer[UInt8, buf_origin],
    length: Int,
    flags: Int32,
    addr_ptr: Pointer[UInt8, addr_origin],
    addr_len: UInt,
) -> Int:
    """Send data to a specific address via sendto(2).

    Args:
        fd: Socket file descriptor.
        buf: Pointer to the data to send.
        length: Number of bytes to send.
        flags: send flags.
        addr_ptr: Pointer to the destination sockaddr.
        addr_len: Length of the destination sockaddr.

    Returns:
        Bytes sent or negated errno on error.
    """
    return Int(
        syscall[__NR_sendto, Scalar[DType.int64]](
            fd, buf, UInt(length), UInt(flags), addr_ptr, addr_len
        )
    )


@always_inline
def _recvfrom[
    buf_origin: MutOrigin,
    addr_origin: MutOrigin,
    len_origin: MutOrigin,
](
    fd: Int32,
    buf: Pointer[UInt8, buf_origin],
    length: Int,
    flags: Int32,
    addr_ptr: Pointer[UInt8, addr_origin],
    addr_len_ptr: Pointer[UInt8, len_origin],
) -> Int:
    """Receive data and source address via recvfrom(2).

    Args:
        fd: Socket file descriptor.
        buf: Pointer to the receive buffer.
        length: Maximum number of bytes to receive.
        flags: recv flags.
        addr_ptr: Pointer to a sockaddr to fill with the source address.
        addr_len_ptr: Pointer to the sockaddr length (in/out).

    Returns:
        Bytes read, 0 on EOF, or negated errno on error.
    """
    return Int(
        syscall[__NR_recvfrom, Scalar[DType.int64]](
            fd, buf, UInt(length), UInt(flags), addr_ptr, addr_len_ptr
        )
    )


@always_inline
def _shutdown(fd: Int32, how: Int32) raises:
    """Shut down part of a full-duplex connection via shutdown(2).

    Args:
        fd: Socket file descriptor.
        how: Shutdown mode (0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR).

    Raises:
        On syscall failure.
    """
    var res = syscall[__NR_shutdown, Scalar[DType.int64]](fd, how)
    _check_for_errors(res)


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
    var optlen = UInt(4)
    var val_p = Pointer(to=val)
    var len_p = Pointer(to=optlen)
    var res = syscall[__NR_getsockopt, Scalar[DType.int64]](
        fd, level, optname, val_p, len_p
    )
    _check_for_errors(res)
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
    var res = syscall[__NR_setsockopt, Scalar[DType.int64]](
        fd, level, optname, tv_p, UInt(16),
    )
    _check_for_errors(res)


@always_inline
def _getsockname[
    addr_origin: MutOrigin,
    len_origin: MutOrigin,
](
    fd: Int32,
    addr_ptr: Pointer[UInt8, addr_origin],
    addr_len_ptr: Pointer[UInt8, len_origin],
) raises:
    """Get the local address of a socket via getsockname(2).

    Args:
        fd: Socket file descriptor.
        addr_ptr: Pointer to a sockaddr to fill.
        addr_len_ptr: Pointer to the sockaddr length (in/out).

    Raises:
        On syscall failure.
    """
    var res = syscall[__NR_getsockname, Scalar[DType.int64]](
        fd, addr_ptr, addr_len_ptr
    )
    _check_for_errors(res)


@always_inline
def _getpeername[
    addr_origin: MutOrigin,
    len_origin: MutOrigin,
](
    fd: Int32,
    addr_ptr: Pointer[UInt8, addr_origin],
    addr_len_ptr: Pointer[UInt8, len_origin],
) raises:
    """Get the peer address of a socket via getpeername(2).

    Args:
        fd: Socket file descriptor.
        addr_ptr: Pointer to a sockaddr to fill.
        addr_len_ptr: Pointer to the sockaddr length (in/out).

    Raises:
        On syscall failure.
    """
    var res = syscall[__NR_getpeername, Scalar[DType.int64]](
        fd, addr_ptr, addr_len_ptr
    )
    _check_for_errors(res)


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
    var res = syscall[__NR_fcntl, Scalar[DType.int64]](fd, Int32(F_GETFL), Int32(0))
    return unsafe_decode_result[DType.int32](res)


@always_inline
def _fcntl_setfl(fd: Int32, flags: Int32) raises:
    """Set file descriptor flags via fcntl(fd, F_SETFL, flags).

    Args:
        fd: File descriptor.
        flags: Flags to set.

    Raises:
        On syscall failure.
    """
    var res = syscall[__NR_fcntl, Scalar[DType.int64]](fd, Int32(F_SETFL), flags)
    _check_for_errors(res)
