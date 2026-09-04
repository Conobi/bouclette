"""Portable I/O error type.

`IOError` is the single error type raised by every failing I/O operation in
boucle. It wraps one Linux errno as a **positive** number, whichever sign the
producer used: kernels and `io_uring`/`epoll` completions report negated
errnos, `SO_ERROR` and libc report positive ones, and `IOError.from_errno`
normalises both to the same value.

It is usable as a typed raised error (`def f() raises IOError`) and, because it
is `Writable`, it can also be raised from a plain `raises` function, where it
degrades to an `Error` carrying its text (e.g. `ECONNREFUSED (111)`).
"""

from boucle.socle.platform import (
    Errno,
    EACCES,
    EADDRINUSE,
    EADDRNOTAVAIL,
    EAFNOSUPPORT,
    EAGAIN,
    EBADF,
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
)


@always_inline
def _errno_name(errno: Int) -> StaticString:
    """Return the symbolic name of a positive errno.

    Covers the errnos boucle itself reasons about. Anything else prints as
    `UNKNOWN` — the number in the message stays exact either way.

    Args:
        errno: A positive errno number, or 0 for "no error".

    Returns:
        The symbolic name, `"SUCCESS"` for 0, or `"UNKNOWN"`.
    """
    if errno == 0:
        return "SUCCESS"
    if errno == EPERM:
        return "EPERM"
    if errno == ENOENT:
        return "ENOENT"
    if errno == EINTR:
        return "EINTR"
    if errno == EBADF:
        return "EBADF"
    if errno == EAGAIN:
        return "EAGAIN"
    if errno == ENOMEM:
        return "ENOMEM"
    if errno == EACCES:
        return "EACCES"
    if errno == EEXIST:
        return "EEXIST"
    if errno == EINVAL:
        return "EINVAL"
    if errno == ENOSYS:
        return "ENOSYS"
    if errno == EADDRINUSE:
        return "EADDRINUSE"
    if errno == EADDRNOTAVAIL:
        return "EADDRNOTAVAIL"
    if errno == EAFNOSUPPORT:
        return "EAFNOSUPPORT"
    if errno == ENETUNREACH:
        return "ENETUNREACH"
    if errno == ECONNABORTED:
        return "ECONNABORTED"
    if errno == ECONNRESET:
        return "ECONNRESET"
    if errno == ENOTCONN:
        return "ENOTCONN"
    if errno == ETIMEDOUT:
        return "ETIMEDOUT"
    if errno == ECONNREFUSED:
        return "ECONNREFUSED"
    if errno == EHOSTUNREACH:
        return "EHOSTUNREACH"
    if errno == EINPROGRESS:
        return "EINPROGRESS"
    if errno == EPIPE:
        return "EPIPE"
    return "UNKNOWN"


struct IOError(TrivialRegisterPassable, Equatable, Writable):
    """Portable I/O error type wrapping a Linux errno.

    The errno is stored as a positive number. Two `IOError`s are equal when
    they carry the same number.
    """

    var _errno: Int
    """The positive errno number; 0 means "no error"."""

    @always_inline("nodebug")
    def __init__(out self, errno: Errno):
        """Create an IOError from a socle `Errno`.

        Args:
            errno: The platform errno (stored negated inside `Errno`).
        """
        self._errno = -Int(errno.id)

    @always_inline("nodebug")
    def __init__(out self, *, positive_errno: Int):
        """Create an IOError from an already-normalised positive errno.

        Args:
            positive_errno: A positive errno number, or 0 for "no error".
        """
        self._errno = positive_errno

    @always_inline("nodebug")
    def __init__(out self, *, error: Error) raises:
        """Create an IOError from an Error whose text is a negated errno.

        Args:
            error: An error raised by the socle syscall layer.

        Raises:
            If the error text is not a negated errno in `[-4095, 0)`.
        """
        self._errno = -Int(Errno(error=error).id)

    @staticmethod
    @always_inline("nodebug")
    def from_errno(errno: Int) -> Self:
        """Create an IOError from an errno of either sign.

        Kernel completions deliver negated errnos (`-111`) while `SO_ERROR`
        and libc deliver positive ones (`111`); both denote the same error, so
        both normalise to the same `IOError`.

        Args:
            errno: An errno number, positive or negative. 0 means "no error".

        Returns:
            An IOError holding the positive form of `errno`.
        """
        return Self(positive_errno=-errno if errno < 0 else errno)

    @staticmethod
    @always_inline
    def from_error(error: Error) -> Self:
        """Convert an Error raised by the socle syscall layer into an IOError.

        The socle layer reports syscall failures as an Error whose text is the
        negated errno. Text that is not an errno means the kernel broke its
        contract (a result outside `[-4095, 0)`); there is no errno to report
        for that, so it becomes EINVAL.

        Unlike `IOError(error=...)` this never raises, so it can be used inside
        a function declared `raises IOError`.

        Args:
            error: The error raised by a socle syscall wrapper.

        Returns:
            An IOError carrying the errno, or EINVAL if the text is not one.
        """
        try:
            return Self.from_errno(Int(String(error)))
        except:
            return Self(positive_errno=EINVAL)

    @always_inline("nodebug")
    def errno_value(self) -> Int:
        """Return the errno as a positive number.

        Returns:
            The positive errno, or 0 when the error denotes success.
        """
        return self._errno

    @always_inline("nodebug")
    def __eq__(self, rhs: Self) -> Bool:
        """Compare two errors by errno number.

        Args:
            rhs: The error to compare against.

        Returns:
            True when both carry the same errno.
        """
        return self._errno == rhs._errno

    @always_inline("nodebug")
    def __ne__(self, rhs: Self) -> Bool:
        """Compare two errors by errno number.

        Args:
            rhs: The error to compare against.

        Returns:
            True when the errnos differ.
        """
        return self._errno != rhs._errno

    @always_inline("nodebug")
    def is_would_block(self) -> Bool:
        """Return True when the operation would block (EAGAIN/EWOULDBLOCK).

        Returns:
            True for EAGAIN, which equals EWOULDBLOCK on Linux.
        """
        return self._errno == EAGAIN

    @always_inline("nodebug")
    def is_connection_reset(self) -> Bool:
        """Return True when the peer reset the connection (ECONNRESET).

        Returns:
            True for ECONNRESET.
        """
        return self._errno == ECONNRESET

    @always_inline("nodebug")
    def is_connection_refused(self) -> Bool:
        """Return True when the peer refused the connection (ECONNREFUSED).

        Returns:
            True for ECONNREFUSED.
        """
        return self._errno == ECONNREFUSED

    @always_inline("nodebug")
    def is_broken_pipe(self) -> Bool:
        """Return True when writing to a closed peer (EPIPE).

        Returns:
            True for EPIPE.
        """
        return self._errno == EPIPE

    @always_inline("nodebug")
    def is_timed_out(self) -> Bool:
        """Return True when the operation timed out (ETIMEDOUT).

        Returns:
            True for ETIMEDOUT.
        """
        return self._errno == ETIMEDOUT

    @always_inline("nodebug")
    def is_interrupted(self) -> Bool:
        """Return True when a signal interrupted the call (EINTR).

        Returns:
            True for EINTR.
        """
        return self._errno == EINTR

    @always_inline("nodebug")
    def is_in_progress(self) -> Bool:
        """Return True when a non-blocking connect is still running.

        Returns:
            True for EINPROGRESS, which is not a failure.
        """
        return self._errno == EINPROGRESS

    @always_inline
    def write_to[W: Writer](self, mut writer: W):
        """Write the errno name followed by its number, e.g. `EPIPE (32)`.

        Args:
            writer: The writer to output to.
        """
        writer.write(_errno_name(self._errno), " (", self._errno, ")")
