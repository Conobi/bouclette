"""Low-level socket syscall wrappers using libc external_call.

Uses external_call instead of raw syscall wrappers to work around
a Mojo 0.26.2 mojopkg deserialization crash when calling through
multiple internal subpackage layers.

All functions accept raw integer / pointer arguments only — no types
from ``boucle.*`` (outside ``boucle.socle``).  The typed-option
bridge lives in ``boucle.net.socket``.
"""

from std.ffi import external_call
from std.memory import UnsafePointer


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
    addr_ptr: UnsafePointer[UInt8, StaticConstantOrigin],
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
    # UnsafePointer(to=val) inline can clobber val's stack slot
    # during external_call arg marshaling.
    var val_p = UnsafePointer(to=val)
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
    addr_ptr: UnsafePointer[UInt8, StaticConstantOrigin],
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
