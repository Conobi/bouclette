"""Low-level socket syscall wrappers using libc external_call.

Uses external_call instead of raw syscall wrappers to work around
a Mojo 0.26.2 mojopkg deserialization crash when calling through
multiple internal subpackage layers.
"""

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import size_of

from boucle.handle import RawHandle, OwnedHandle
from boucle.net.addr import SocketAddr
from boucle.net.ip import IpAddrV4, IpAddrV6
from boucle.net.options import AddrFamily, SocketType, SocketFlags, Protocol, Backlog
from boucle._sys.linux.raw import (
    sockaddr_in,
    sockaddr_in6,
    socklen_t,
    AF_INET,
    AF_INET6,
)


@always_inline
def _socket(
    domain: AddrFamily,
    type: SocketType,
    flags: SocketFlags,
    protocol: Protocol,
) raises -> OwnedHandle:
    var type_flags = type.id | Int32(flags.value)
    var res = external_call["socket", Int32](
        Int32(domain.id), type_flags, Int32(protocol.id)
    )
    if res < 0:
        raise String(Int(res))
    return OwnedHandle(raw=res)


@always_inline
def _bind[Addr: SocketAddr](ref handle: OwnedHandle, ref addr: Addr) raises:
    var res = external_call["bind", Int32](
        handle.raw(), addr.addr_unsafe_ptr(), Int32(Addr.ADDR_LEN)
    )
    if res < 0:
        raise String(Int(res))


@always_inline
def _listen(ref handle: OwnedHandle, backlog: Backlog) raises:
    var res = external_call["listen", Int32](handle.raw(), backlog.value)
    if res < 0:
        raise String(Int(res))


@always_inline
def _setsockopt(
    ref handle: OwnedHandle,
    level: Int32,
    optname: Int32,
    value: Int32,
) raises:
    var val = value
    # Pre-capture the pointer in a named local — passing
    # UnsafePointer(to=val) inline can clobber val's stack slot
    # during external_call arg marshaling.
    var val_p = UnsafePointer(to=val)
    var res = external_call["setsockopt", Int32](
        handle.raw(),
        level,
        optname,
        val_p,
        UInt32(4),
    )
    if res < 0:
        raise String(Int(res))


@always_inline
def _connect[Addr: SocketAddr](ref handle: OwnedHandle, ref addr: Addr) raises:
    var res = external_call["connect", Int32](
        handle.raw(), addr.addr_unsafe_ptr(), Int32(Addr.ADDR_LEN)
    )
    if res < 0:
        raise String(Int(res))


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
