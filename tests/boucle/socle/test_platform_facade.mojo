"""The platform facade exports everything the portable layer imports.

`boucle/socle/platform.mojo` is the single seam between the public API
and a concrete OS. If a name disappears from it, some portable module
stops compiling — this test makes that failure land here, next to the
seam, instead of scattered across `boucle/error.mojo`, `boucle/handle.mojo`,
`boucle/ctypes/`, `boucle/net/`, `boucle/coroutine/` and `boucle/watch/`.

It also pins the invariant the seam exists for: no module above
`boucle.socle` may name an OS package directly.
"""

from std.ffi import external_call
from std.sys.info import size_of
from std.testing import assert_equal, assert_true

from boucle.socle.platform import (
    platform_name,
    # Errno vocabulary — boucle/error.mojo, boucle/watch/outcome.mojo.
    Errno,
    EACCES,
    EADDRINUSE,
    EADDRNOTAVAIL,
    EAFNOSUPPORT,
    EAGAIN,
    EBADF,
    ECANCELED,
    ECONNABORTED,
    ECONNREFUSED,
    ECONNRESET,
    EEXIST,
    EHOSTUNREACH,
    EINPROGRESS,
    EINTR,
    EINVAL,
    ENETUNREACH,
    ENOENT,
    ENOMEM,
    ENOSYS,
    ENOTCONN,
    EPERM,
    EPIPE,
    ETIMEDOUT,
    # Raw handles — boucle/handle.mojo, boucle/watch/accept.mojo.
    UnsafeFd,
    close,
    close_unchecked,
    unsafe_fd_as_arg,
    # C scalars — boucle/ctypes/__init__.mojo.
    c_void,
    c_char,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_size_t,
    c_ssize_t,
    # Address layouts and byte order — boucle/net/addr.mojo.
    __be32,
    sockaddr_in,
    sockaddr_in6,
    socklen_t,
    _to_be,
    # Socket syscalls — boucle/net/socket.mojo.
    _socket,
    _bind,
    _listen,
    _raw_accept4,
    _setsockopt,
    _connect,
    _recv,
    _send,
    _sendto,
    _recvfrom,
    _shutdown,
    _setsockopt_timeval,
    _fcntl_getfl,
    _fcntl_setfl,
    _getsockopt_int,
    _getsockname,
    _getpeername,
    # Socket option constants — boucle/net/options.mojo, socket.mojo.
    AF_UNSPEC,
    AF_UNIX,
    AF_INET,
    AF_INET6,
    SOCK_STREAM,
    SOCK_DGRAM,
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
    # Coroutine stacks — boucle/coroutine/_stack.mojo.
    _UcontextStack,
)


def test_platform_name_is_a_supported_os() raises:
    """The facade names the OS it selected."""
    assert_true(
        platform_name == "linux"
        or platform_name == "darwin"
        or platform_name == "windows",
        String("unexpected platform name: ", platform_name),
    )


def test_errno_constants_are_reachable() raises:
    """The errno vocabulary the public layer reasons about resolves."""
    assert_equal(Int(EAGAIN), 11)
    assert_equal(Int(EINVAL), 22)
    assert_equal(Int(EPIPE), 32)
    assert_equal(Int(ECANCELED), 125)
    assert_equal(Int(ENOTCONN), 107)
    assert_equal(Int(ECONNREFUSED), 111)
    # `Errno` stores the negated form; only the pairing matters here.
    assert_equal(Int(-Errno.EAGAIN.id), Int(EAGAIN))
    assert_equal(Int(-Errno.ETIMEDOUT.id), Int(ETIMEDOUT))
    # Touch the rest so a dropped re-export cannot pass unnoticed.
    var sum_of_the_rest = (
        Int(EACCES)
        + Int(EADDRINUSE)
        + Int(EADDRNOTAVAIL)
        + Int(EAFNOSUPPORT)
        + Int(EBADF)
        + Int(ECONNABORTED)
        + Int(ECONNRESET)
        + Int(EEXIST)
        + Int(EHOSTUNREACH)
        + Int(EINPROGRESS)
        + Int(EINTR)
        + Int(ENETUNREACH)
        + Int(ENOENT)
        + Int(ENOMEM)
        + Int(ENOSYS)
        + Int(EPERM)
    )
    assert_true(sum_of_the_rest > 0)


def test_handle_primitives_are_reachable() raises:
    """`close`/`close_unchecked`/`unsafe_fd_as_arg` come from the facade."""
    assert_equal(size_of[UnsafeFd](), 4)

    # A real descriptor to exercise both close forms on: a duplicate of
    # stdout, which every process has and which nothing else here uses.
    var dup_of_stdout = external_call["dup", UnsafeFd](UnsafeFd(1))
    assert_true(dup_of_stdout > 0, "dup(stdout) should succeed")
    assert_equal(
        Int(unsafe_fd_as_arg(dup_of_stdout)), Int(dup_of_stdout)
    )
    close_unchecked(unsafe_fd=dup_of_stdout)

    # Both entry points reject a negative descriptor rather than handing
    # it to the kernel.
    var raised = False
    try:
        _ = unsafe_fd_as_arg(UnsafeFd(-1))
    except:
        raised = True
    assert_true(raised, "unsafe_fd_as_arg(-1) should raise")

    raised = False
    try:
        close(unsafe_fd=UnsafeFd(-1))
    except:
        raised = True
    assert_true(raised, "close(-1) should raise")


def test_c_scalar_aliases_are_reachable() raises:
    """The ctypes bridge re-exports these; their widths are LP64."""
    assert_equal(size_of[c_void](), 1)
    assert_equal(size_of[c_char](), 1)
    assert_equal(size_of[c_int](), 4)
    assert_equal(size_of[c_uint](), 4)
    assert_equal(size_of[c_long](), 8)
    assert_equal(size_of[c_ulong](), 8)
    assert_equal(size_of[c_size_t](), 8)
    assert_equal(size_of[c_ssize_t](), 8)


def test_address_layouts_are_reachable() raises:
    """`boucle/net/addr.mojo` builds its storage types out of these."""
    assert_equal(size_of[sockaddr_in](), 16)
    assert_equal(size_of[sockaddr_in6](), 28)
    assert_equal(size_of[socklen_t](), 4)
    assert_equal(size_of[__be32](), 4)
    # `_to_be` is its own inverse on a little-endian host.
    var port = SIMD[DType.uint16, 1](8080)
    assert_equal(Int(_to_be[DType.uint16, 1](port)[0]), 0x901F)
    assert_equal(Int(_to_be[DType.uint16, 1](_to_be[DType.uint16, 1](port))[0]), 8080)


def test_socket_syscalls_are_reachable() raises:
    """The wrappers `boucle/net/socket.mojo` wraps in `IOError` resolve."""
    # One real round trip proves the whole chain is callable, not merely
    # importable: create, query, and close a non-blocking TCP socket.
    var fd = _socket(
        Int32(AF_INET), Int32(SOCK_STREAM) | Int32(O_NONBLOCK), Int32(0)
    )
    assert_true(fd >= 0, "socket() should succeed")
    _setsockopt(fd, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), Int32(1))
    assert_equal(
        Int(_getsockopt_int(fd, Int32(SOL_SOCKET), Int32(SO_ERROR))), 0
    )
    assert_true(
        (_fcntl_getfl(fd) & Int32(O_NONBLOCK)) != 0,
        "socket should have been created non-blocking",
    )
    _fcntl_setfl(fd, _fcntl_getfl(fd))
    close_unchecked(unsafe_fd=fd)

    # The remaining wrappers need a peer or a bound address to exercise;
    # naming them here is what pins them to the facade.
    _ = _bind
    _ = _listen
    _ = _raw_accept4
    _ = _connect
    _ = _recv
    _ = _send
    _ = _sendto
    _ = _recvfrom
    _ = _shutdown
    _ = _setsockopt_timeval
    _ = _getsockname
    _ = _getpeername


def test_socket_option_constants_are_reachable() raises:
    """The values `boucle/net/options.mojo` asserts against."""
    assert_equal(Int(AF_UNSPEC), 0)
    assert_equal(Int(AF_UNIX), 1)
    assert_equal(Int(AF_INET), 2)
    assert_equal(Int(AF_INET6), 10)
    assert_equal(Int(SOCK_STREAM), 1)
    assert_equal(Int(SOCK_DGRAM), 2)
    assert_equal(Int(SOL_SOCKET), 1)
    assert_equal(Int(IPPROTO_IPV6), 41)
    assert_equal(Int(IPV6_V6ONLY), 26)
    assert_equal(Int(O_NONBLOCK), 2048)
    assert_equal(Int(O_CLOEXEC), 524288)
    assert_equal(Int(MSG_NOSIGNAL), 16384)
    var sum_of_the_rest = (
        Int(SO_REUSEADDR)
        + Int(SO_REUSEPORT)
        + Int(SO_RCVTIMEO)
        + Int(SO_SNDTIMEO)
        + Int(SO_ERROR)
    )
    assert_true(sum_of_the_rest > 0)


def test_coroutine_stack_is_reachable() raises:
    """`boucle/coroutine/_stack.mojo` aliases `_CoroStack` to this."""
    var stack = _UcontextStack(64 * 1024)
    assert_true(
        not stack.has_pool_ref(), "a fresh stack belongs to no pool yet"
    )


def main() raises:
    test_platform_name_is_a_supported_os()
    test_errno_constants_are_reachable()
    test_handle_primitives_are_reachable()
    test_c_scalar_aliases_are_reachable()
    test_address_layouts_are_reachable()
    test_socket_syscalls_are_reachable()
    test_socket_option_constants_are_reachable()
    test_coroutine_stack_is_reachable()
    print("PASS: test_platform_facade.mojo")
