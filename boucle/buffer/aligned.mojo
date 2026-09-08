"""`AlignedBuffer` — fixed-capacity byte buffer with alignment guarantees.

Backed by `unsafe_alloc[Byte](capacity, alignment=alignment)`, this type
provides a contiguous byte region whose start address satisfies the
requested alignment. Useful for O_DIRECT I/O, DMA buffers, and any
kernel interface that requires page- or sector-aligned memory.

The buffer is `Movable` and `Sized` but not `Copyable`. Overflow on
`append` or `extend` calls `abort()` unconditionally — there is no
fallible insertion path.
"""

from std.memory import Pointer, unsafe_memset
from std.memory.alloc import unsafe_alloc
from std.os import abort


struct AlignedBuffer(Movable, Sized):
    """A fixed-capacity byte buffer whose backing memory is aligned."""

    var _ptr: Pointer[UInt8, MutUntrackedOrigin]
    var _len: Int
    var _cap: Int
    var _alignment: Int

    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------

    def __init__(out self, *, capacity: Int, alignment: Int = 1):
        """Allocate `capacity` bytes aligned to `alignment`."""
        if capacity <= 0:
            abort("AlignedBuffer: capacity must be positive")
        if alignment <= 0 or (alignment & (alignment - 1)) != 0:
            abort("AlignedBuffer: alignment must be a positive power of two")
        self._ptr = unsafe_alloc[UInt8](capacity, alignment=alignment)
        self._len = 0
        self._cap = capacity
        self._alignment = alignment

    def __init__(
        out self, *, capacity: Int, alignment: Int = 1, fill: UInt8
    ):
        """Allocate and fill `capacity` bytes with `fill`.

        Sets length equal to capacity so the entire buffer is immediately
        addressable.
        """
        if capacity <= 0:
            abort("AlignedBuffer: capacity must be positive")
        if alignment <= 0 or (alignment & (alignment - 1)) != 0:
            abort("AlignedBuffer: alignment must be a positive power of two")
        self._ptr = unsafe_alloc[UInt8](capacity, alignment=alignment)
        self._cap = capacity
        self._alignment = alignment
        unsafe_memset(self._ptr, fill, capacity)
        self._len = capacity

    # ------------------------------------------------------------------
    # Move / destroy
    # ------------------------------------------------------------------

    def __init__(out self, *, deinit move: Self):
        self._ptr = move._ptr
        self._len = move._len
        self._cap = move._cap
        self._alignment = move._alignment

    def __deinit__(deinit self):
        """Free the backing allocation (no-op when moved-from)."""
        if Int(self._ptr) != 0:
            self._ptr.unsafe_free()

    # ------------------------------------------------------------------
    # Sized
    # ------------------------------------------------------------------

    def __len__(self) -> Int:
        return self._len

    # ------------------------------------------------------------------
    # Element access
    # ------------------------------------------------------------------

    def __getitem__(self, index: Int) -> UInt8:
        """Read the byte at `index` (bounds-checked via `debug_assert`)."""
        debug_assert(0 <= index < self._len, "AlignedBuffer: index out of range")
        return self._ptr.unsafe_offset(index).unsafe_load()

    def __setitem__(mut self, index: Int, value: UInt8):
        """Write `value` at `index` (bounds-checked via `debug_assert`)."""
        debug_assert(0 <= index < self._len, "AlignedBuffer: index out of range")
        self._ptr.unsafe_offset(index).unsafe_store(value)

    # ------------------------------------------------------------------
    # Mutation
    # ------------------------------------------------------------------

    def append(mut self, b: UInt8):
        """Append a single byte. Aborts unconditionally if full."""
        if self._len >= self._cap:
            abort("AlignedBuffer.append: buffer full")
        self._ptr.unsafe_offset(self._len).unsafe_store(b)
        self._len += 1

    def extend(mut self, data: Span[UInt8, _]):
        """Append all bytes from `data`. Aborts if overflow."""
        if self._len + len(data) > self._cap:
            abort("AlignedBuffer.extend: would overflow")
        for i in range(len(data)):
            self._ptr.unsafe_offset(self._len + i).unsafe_store(data[i])
        self._len += len(data)

    def resize(mut self, new_len: Int):
        """Set the used length without touching the backing bytes.

        The caller is responsible for any bytes between the old and new
        lengths being meaningful.
        """
        debug_assert(
            0 <= new_len <= self._cap, "AlignedBuffer.resize: out of range"
        )
        self._len = new_len

    def clear(mut self):
        """Set the used length to zero."""
        self._len = 0

    # ------------------------------------------------------------------
    # Views
    # ------------------------------------------------------------------

    def as_span(ref self) -> Span[UInt8, origin_of(self)]:
        """Borrow the used region as a read-only span."""
        return Span[UInt8, origin_of(self)](
            unsafe_ptr=Pointer[UInt8, origin_of(self)](
                unsafe_from_address=Int(self._ptr)
            ),
            length=self._len,
        )

    # ------------------------------------------------------------------
    # Accessors
    # ------------------------------------------------------------------

    def capacity(self) -> Int:
        """Total buffer capacity in bytes, fixed at construction."""
        return self._cap

    def alignment(self) -> Int:
        """Alignment guarantee in bytes, fixed at construction."""
        return self._alignment

    def unsafe_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        """Raw pointer to byte 0; valid for `capacity()` bytes while alive."""
        return self._ptr
