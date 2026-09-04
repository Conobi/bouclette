from std.sys.info import size_of, align_of


@always_inline("nodebug")
def _aligned_u64[T: AnyType]():
    """Compile-time assertion that a type has at least 8-byte alignment.
    [Linux]: https://github.com/torvalds/linux/blob/v6.7/include/uapi/linux/types.h#L47.
    """
    comptime assert align_of[T]() >= 8


@always_inline("nodebug")
def _size_eq[T: AnyType, I: AnyType]():
    """Compile-time assertion that two types have the same size."""
    comptime assert size_of[T]() == size_of[I]()


@always_inline("nodebug")
def _size_eq[T: AnyType, size: IntLiteral]():
    """Compile-time assertion that a type has the given size."""
    comptime assert size_of[T]() == size


@always_inline("nodebug")
def _align_eq[T: AnyType, I: AnyType]():
    """Compile-time assertion that two types have the same alignment."""
    comptime assert align_of[T]() == align_of[I]()


@always_inline("nodebug")
def _align_eq[T: AnyType, align: IntLiteral]():
    """Compile-time assertion that a type has the given alignment."""
    comptime assert align_of[T]() == align


@always_inline("nodebug")
def _size_eq[T: AnyType](size: Int):
    """Runtime assertion that a type has the given size."""
    debug_assert(size_of[T]() == size, "size mismatch")


@always_inline("nodebug")
def _align_eq[T: AnyType](align: Int):
    """Runtime assertion that a type has the given alignment."""
    debug_assert(align_of[T]() == align, "alignment mismatch")
