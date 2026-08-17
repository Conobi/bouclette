from std.ffi import external_call
from boucle.socle.linux.raw import (
    EACCES,
    EADDRINUSE,
    EADDRNOTAVAIL,
    EAGAIN,
    EBADF,
    ECONNABORTED,
    ECONNREFUSED,
    ECONNRESET,
    EEXIST,
    EINTR,
    EINVAL,
    ENOENT,
    ENOMEM,
    ENOSYS,
    ENOTCONN,
    EPERM,
    EPIPE,
    ETIMEDOUT,
    EWOULDBLOCK,
)


@always_inline("nodebug")
def get_errno() -> Int32:
    """Reads the thread-local errno set by libc wrappers.

    Use this after an `external_call` to a libc function that signals
    failure by returning -1 (e.g. `epoll_create1`, `epoll_ctl`,
    `epoll_wait`). Raw syscalls invoked via `syscall[]` return the
    negated errno directly in their return value — those callers should
    use `is_eintr` and `unsafe_decode_result` instead.
    """
    return external_call[
        "__errno_location", UnsafePointer[Int32, MutUntrackedOrigin]
    ]()[]


struct Errno(TrivialRegisterPassable, Writable):
    """I/O error type wrapping a Linux errno.

    Linux returns negated error numbers, kept in range [-4095, 0).
    """

    comptime EACCES = Self(errno=EACCES)
    comptime EADDRINUSE = Self(errno=EADDRINUSE)
    comptime EADDRNOTAVAIL = Self(errno=EADDRNOTAVAIL)
    comptime EAGAIN = Self(errno=EAGAIN)
    comptime EBADF = Self(errno=EBADF)
    comptime ECONNABORTED = Self(errno=ECONNABORTED)
    comptime ECONNREFUSED = Self(errno=ECONNREFUSED)
    comptime ECONNRESET = Self(errno=ECONNRESET)
    comptime EEXIST = Self(errno=EEXIST)
    comptime EINTR = Self(errno=EINTR)
    comptime EINVAL = Self(errno=EINVAL)
    comptime ENOENT = Self(errno=ENOENT)
    comptime ENOMEM = Self(errno=ENOMEM)
    comptime ENOSYS = Self(errno=ENOSYS)
    comptime ENOTCONN = Self(errno=ENOTCONN)
    comptime EPERM = Self(errno=EPERM)
    comptime EPIPE = Self(errno=EPIPE)
    comptime ETIMEDOUT = Self(errno=ETIMEDOUT)
    comptime EWOULDBLOCK = Self(errno=EWOULDBLOCK)

    var id: Int16

    @always_inline("nodebug")
    def __init__(out self, *, errno: UInt16):
        """Creates an Errno from a positive errno number.

        Used by comptime constants. The range is validated via debug_assert
        since comptime evaluation cannot call raising functions.
        """
        self.id = -Int16(errno)
        debug_assert(
            self.id >= -4095 and self.id < 0, "error number out of range"
        )

    @always_inline("nodebug")
    def __init__(out self, *, error: Error) raises:
        """Creates an Errno from an Error whose string is a negated errno."""
        self = Self(negated_errno=Int16(Int(String(error))))

    @always_inline("nodebug")
    def __init__(out self, *, negated_errno: Int16) raises:
        """Creates an Errno from a negated errno value.

        Raises:
            If `negated_errno` is outside the valid Linux range [-4095, 0).
        """
        self.id = negated_errno
        if not (self.id >= -4095 and self.id < 0):
            raise "error number out of range"

    @always_inline("nodebug")
    def __is__(self, rhs: Self) -> Bool:
        return self.id == rhs.id

    @always_inline("nodebug")
    def __isnot__(self, rhs: Self) -> Bool:
        return self.id != rhs.id

    @always_inline
    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.id)


@always_inline("nodebug")
def is_eintr(neg_errno: Scalar[DType.int64]) -> Bool:
    """True when a syscall returned -EINTR (interrupted by a signal).

    Linux returns negated error numbers; EINTR is errno 4, so the signed
    syscall result is -4 when the call was interrupted by a signal.
    """
    return neg_errno == -Scalar[DType.int64](EINTR)


@always_inline("nodebug")
def _check_for_errors(raw: Scalar[DType.int64]) raises:
    """Raises when `raw` is a negated errno from a Linux syscall.

    Raises:
        If `raw` is negative but outside [-4095, 0) (kernel contract violation).
        If `raw` is a valid negated errno, raises its string representation.
    """
    if raw < 0:
        if raw < -4095:
            raise "error number out of range: " + String(raw)
        raise String(raw)


@always_inline("nodebug")
def _zero_result(raw: Scalar[DType.int64]):
    debug_assert(raw == 0, "non-zero result")


@always_inline("nodebug")
def unsafe_decode_result[
    type: DType
](raw: Scalar[DType.int64]) raises -> Scalar[type]:
    """Checks for errors and converts `raw` to the given scalar type.

    Raises:
        If `raw` is a negated errno (via `_check_for_errors`).
        If the conversion to `type` is lossy.
    """
    _check_for_errors(raw)
    var res = raw.cast[type]()
    if res.cast[DType.int64]() != raw:
        raise "conversion is not lossless"
    return res


@always_inline("nodebug")
def unsafe_decode_ptr(
    unsafe_ptr: UnsafePointer[Int8, StaticConstantOrigin],
) raises:
    _check_for_errors(Scalar[DType.int64](Int(unsafe_ptr)))


@always_inline("nodebug")
def unsafe_decode_none(raw: Scalar[DType.int64]) raises:
    """Checks that `raw` is zero (success) or a valid negated errno.

    Raises:
        If `raw` is non-zero but outside [-4095, 0) (kernel contract violation).
        If `raw` is a valid negated errno, raises its string representation.
    """
    if raw != 0:
        if not (raw >= -4095 and raw < 0):
            raise "error number out of range: " + String(raw)
        raise String(raw)
