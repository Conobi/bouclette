"""Buffer types for I/O operations."""


struct IOBuffer:
    """A view over a contiguous memory region for I/O operations.

    Does not own the memory — caller keeps backing storage alive.
    """

    var unsafe_ptr: Pointer[Int8, ImmStaticOrigin]
    var len: UInt

    @always_inline("nodebug")
    def __init__(out self, ref data: List[UInt8]):
        self.unsafe_ptr = Pointer[Int8, ImmStaticOrigin](
            unsafe_from_address=Int(data.unsafe_ptr())
        )
        self.len = UInt(len(data))

    @always_inline("nodebug")
    def __init__(
        out self,
        *,
        unsafe_ptr: Pointer[Int8, ImmStaticOrigin],
        len: UInt,
    ):
        self.unsafe_ptr = unsafe_ptr
        self.len = len
