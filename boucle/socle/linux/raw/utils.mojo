from std.sys.info import is_64bit as _is_64bit, CompilationTarget
from std.bit import byte_swap
from std.memory import Pointer


@always_inline("nodebug")
def is_64bit() -> Bool:
    return _is_64bit()


@always_inline("nodebug")
def is_big_endian() -> Bool:
    return not is_little_endian()


@always_inline("nodebug")
def is_little_endian() -> Bool:
    var val = UInt16(0x0001)
    var bytes = Pointer(to=val).unsafe_bitcast[UInt8]()
    return bytes[] == 1


@always_inline("nodebug")
def _to_be[type: DType, size: Int](value: SIMD[type, size]) -> SIMD[type, size]:
    comptime if is_big_endian():
        return value
    else:
        return byte_swap(value)


struct DTypeArray[
    dtype: DType,
    size: Int,
](TrivialRegisterPassable, Sized, Movable, ImplicitlyCopyable, Defaultable):
    """A fixed size sequence of DType elements.

    Parameters:
        dtype: The type of the elements in the array.
        size: The size of the array.
    """

    comptime type = __mlir_type[
        `!pop.array<`, Self.size.__mlir_index__(), `, `, Scalar[Self.dtype], `>`
    ]

    var array: Self.type
    """The underlying storage for the array."""

    # ===------------------------------------------------------------------===#
    # Life cycle methods
    # ===------------------------------------------------------------------===#

    @always_inline
    def __init__(out self):
        """Constructs a default DTypeArray."""
        Self._is_valid()
        self.array = __mlir_op.`pop.array.repeat`[_type = Self.type](
            Scalar[Self.dtype]()
        )

    @always_inline
    def __init__(out self, *, unsafe_uninitialized: Bool):
        """Constructs a DTypeArray with uninitialized memory.
        Note that this is highly unsafe and should be used with caution.

        Args:
            unsafe_uninitialized: A boolean to indicate if the array
                should be initialized. Always set to `True`
                (it's not actually used inside the constructor).
        """
        self.array = __mlir_op.`kgen.param.constant`[
            _type = Self.type,
            value = __mlir_attr[`#kgen.unknown : `, Self.type],
        ]()

    @always_inline
    def __init__(out self, fill: Scalar[Self.dtype]):
        """Constructs a DTypeArray where each element is the supplied `fill`.

        Args:
            fill: The element to fill each index.
        """
        Self._is_valid()
        self.array = __mlir_op.`pop.array.repeat`[_type = Self.type](fill)

    @always_inline
    def __init__(out self, *, other: Self):
        """Explicitly copy constructs a DTypeArray.

        Args:
            other: The DTypeArray to copy.
        """
        self.array = other.array

    @always_inline("nodebug")
    @staticmethod
    def _non_zero_size():
        comptime assert Self.size > 0, "the number of elements in an initialized `DTypeArray` must be > 0"

    @always_inline("nodebug")
    @staticmethod
    def _is_valid():
        Self._non_zero_size()
        pass

    # ===------------------------------------------------------------------===#
    # Operator dunders
    # ===------------------------------------------------------------------===#

    @always_inline("nodebug")
    def __getitem__[idx: UInt](self) -> Scalar[Self.dtype]:
        """Get the element at the given index.

        Parameters:
            idx: The index of the element.

        Returns:
            The element at the given index.
        """
        Self._non_zero_size()
        comptime assert idx < UInt(Self.size), "index must be within bounds"

        return __mlir_op.`pop.array.get`[
            _type = Scalar[Self.dtype],
            index = idx.__mlir_index__(),
        ](self.array)

    @always_inline("nodebug")
    def __getitem__(ref self, idx: UInt) -> Scalar[Self.dtype]:
        """Get the element at the given index.

        Args:
            idx: The index of the element.

        Returns:
            The element at the given index.
        """
        Self._non_zero_size()
        debug_assert(idx < UInt(Self.size), "index must be within bounds")
        return Pointer(to=self.array).unsafe_bitcast[Scalar[Self.dtype]]()[
            unsafe_offset=Int(idx)
        ]

    # ===------------------------------------------------------------------=== #
    # Trait implementations
    # ===------------------------------------------------------------------=== #

    @always_inline("nodebug")
    def __len__(self) -> Int:
        """Returns the length of the array. This is a known constant value.

        Returns:
            The size of the array.
        """
        return Self.size


@always_inline("nodebug")
def _pick_int[x86: Int, arm: Int]() -> Int:
    """Select an Int value based on the target architecture."""
    comptime if CompilationTarget.is_x86():
        return x86
    else:
        return arm
