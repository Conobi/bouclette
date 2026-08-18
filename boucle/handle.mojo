"""Portable I/O resource handle types."""

from boucle.socle.linux.fd import (
    UnsafeFd,
    close,
    close_unchecked,
    unsafe_fd_as_arg,
)

comptime RawHandle = UnsafeFd
"""A raw, unowned file descriptor / handle value. Alias for Int32."""


struct OwnedHandle(Movable):
    """An owned I/O resource handle with RAII semantics.

    Automatically closes the underlying file descriptor on destruction.
    Use `__moveinit__` to transfer ownership.
    """

    var _raw: RawHandle

    @always_inline("nodebug")
    def __init__(out self, *, raw: RawHandle) raises:
        """Creates an OwnedHandle from a raw handle value.

        Raises:
            If `raw` is negative.
        """
        if raw < 0:
            raise "invalid handle"
        self._raw = raw

    @always_inline("nodebug")
    def __init__(out self, *, deinit move: Self):
        self._raw = move._raw

    @always_inline("nodebug")
    def __deinit__(deinit self):
        close_unchecked(unsafe_fd=self._raw)

    @always_inline("nodebug")
    def raw(self) raises -> RawHandle:
        """Returns the underlying raw handle value.

        Raises:
            If the stored handle is somehow invalid (negative).
        """
        return unsafe_fd_as_arg(self._raw)
