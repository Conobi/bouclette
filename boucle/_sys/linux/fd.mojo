from std.ffi import external_call

comptime UnsafeFd = Int32
comptime NoFd: UnsafeFd = -1


@always_inline("nodebug")
def unsafe_fd_as_arg(unsafe_fd: UnsafeFd) raises -> UnsafeFd:
    """Validates and returns a file descriptor.

    Raises:
        If `unsafe_fd` is negative.
    """
    if unsafe_fd < 0:
        raise "invalid file descriptor"
    return unsafe_fd


@always_inline
def close(*, unsafe_fd: UnsafeFd) raises:
    """Closes an unsafe file descriptor.

    Raises:
        If `unsafe_fd` is negative or `close(2)` returns non-zero.
    """
    var res = external_call["close", Int32](unsafe_fd_as_arg(unsafe_fd))
    if res != 0:
        raise "close failed"


@always_inline
def close_unchecked(*, unsafe_fd: UnsafeFd):
    """Closes an unsafe file descriptor without raising.

    Intended for destructor paths (`__del__`) that cannot propagate errors.
    Uses `debug_assert` for validation — prefer `close` in non-destructor code.
    """
    debug_assert(unsafe_fd > -1, "invalid file descriptor")
    var res = external_call["close", Int32](unsafe_fd)
    debug_assert(res == 0, "non-zero result from close")


@always_inline
def dup(*, unsafe_fd: UnsafeFd) raises -> UnsafeFd:
    """Duplicates a file descriptor.

    Raises:
        If `unsafe_fd` is negative or `dup(2)` fails.
    """
    var res = external_call["dup", Int32](unsafe_fd_as_arg(unsafe_fd))
    if res < 0:
        raise String(Int(res))
    return res
