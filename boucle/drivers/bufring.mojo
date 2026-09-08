"""Provided-buffer ring (IORING_REGISTER_PBUF_RING) for zero-copy recv.

A user-mapped ring of `io_uring_buf` entries, registered with io_uring
under a `bgid` (buffer group id). Replaces the older
`IORING_OP_PROVIDE_BUFFERS` SQE-per-reprovide path: returning a buffer
is a userspace store + atomic store-release on the ring tail, no
syscall, no kernel buffer-pool tree.

Layout per kernel: ring entries are `struct io_uring_buf { addr, len,
bid, resv }` -- 16 bytes each. The first slot's last 2 bytes (offset
14..15) overlay the ring tail. The user writes `tail` there with a
store-release; the kernel reads it with a load-acquire.
"""

from boucle.socle.ptr import null_ptr
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc as _heap_alloc
from std.sys.info import size_of


# ── Constants ──────────────────────────────────────────────────────────

comptime _IO_URING_BUF_SIZE: Int = 16
comptime _IO_URING_BUF_TAIL_OFFSET: Int = 14

# Named field offsets for self-documenting _write_entry code.
# struct io_uring_buf { __u64 addr; __u32 len; __u16 bid; __u16 resv; }
comptime _BUF_ADDR_OFFSET: Int = 0
comptime _BUF_LEN_OFFSET: Int = 8
comptime _BUF_BID_OFFSET: Int = 12


def _verify_io_uring_buf_layout():
    """Compile-time layout verification for struct io_uring_buf.

    struct io_uring_buf { __u64 addr; __u32 len; __u16 bid; __u16 resv; }
    Total: 8 + 4 + 2 + 2 = 16 bytes.
    Tail overlay: bid(12) + resv(14) -- tail is at offset 14 within slot 0.
    """
    comptime assert size_of[UInt64]() == 8, "UInt64 size mismatch"
    comptime assert size_of[UInt32]() == 4, "UInt32 size mismatch"
    comptime assert size_of[UInt16]() == 2, "UInt16 size mismatch"
    comptime assert (
        _IO_URING_BUF_SIZE
        == size_of[UInt64]()
        + size_of[UInt32]()
        + size_of[UInt16]()
        + size_of[UInt16]()
    ), "io_uring_buf size mismatch"
    comptime assert (
        _IO_URING_BUF_TAIL_OFFSET
        == size_of[UInt64]() + size_of[UInt32]() + size_of[UInt16]()
    ), "io_uring_buf tail offset mismatch"
    comptime assert _BUF_ADDR_OFFSET == 0, "BUF_ADDR_OFFSET mismatch"
    comptime assert (
        _BUF_LEN_OFFSET == size_of[UInt64]()
    ), "BUF_LEN_OFFSET mismatch"
    comptime assert (
        _BUF_BID_OFFSET == size_of[UInt64]() + size_of[UInt32]()
    ), "BUF_BID_OFFSET mismatch"


comptime _LAYOUT_VERIFIED: None = _verify_io_uring_buf_layout()


# ── Helpers ────────────────────────────────────────────────────────────

def _next_pow2(n: Int) -> Int:
    """Round `n` up to the next power of 2 (returns `n` if already one)."""
    var p = 1
    while p < n:
        p = p << 1
    return p


# ── BufRing ────────────────────────────────────────────────────────────

struct BufRing(Movable):
    """A registered provided-buffer ring.

    Use after registering with the driver or CompletionLoop. The kernel
    selects buffers from this ring per multishot recv. Return a consumed
    buffer via `add_buffer(buf_id)` after processing the CQE -- userspace
    only.
    """

    var ring_addr: Pointer[UInt8, MutUntrackedOrigin]
    var ring_entries: UInt32
    var mask: UInt32
    var bgid: UInt16
    var buf_base: Pointer[UInt8, MutUntrackedOrigin]
    var buf_size: UInt32
    var buf_count: UInt32
    var owns_ring: Bool

    def __init__(
        out self,
        ring_addr: Pointer[UInt8, MutUntrackedOrigin],
        ring_entries: UInt32,
        bgid: UInt16,
        buf_base: Pointer[UInt8, MutUntrackedOrigin],
        buf_size: UInt32,
        buf_count: UInt32,
    ):
        """Construct a BufRing from pre-allocated ring memory.

        Args:
            ring_addr: Pointer to the ring memory (entries * 16 bytes).
            ring_entries: Number of ring slots (must be a power of 2).
            bgid: Buffer group ID this ring is registered under.
            buf_base: Base pointer for the data buffers.
            buf_size: Size of each individual data buffer in bytes.
            buf_count: Actual number of data buffers in buf_base
                       (may be less than ring_entries when count was
                       rounded up to a power of 2).
        """
        debug_assert(
            ring_entries > 0 and (ring_entries & (ring_entries - 1)) == 0,
            "ring_entries must be a power of 2",
        )
        debug_assert(
            buf_count > 0 and buf_count <= ring_entries,
            "buf_count must be in (0, ring_entries]",
        )
        self.ring_addr = ring_addr
        self.ring_entries = ring_entries
        self.mask = ring_entries - UInt32(1)
        self.bgid = bgid
        self.buf_base = buf_base
        self.buf_size = buf_size
        self.buf_count = buf_count
        self.owns_ring = True

    def __init__(out self):
        """Empty BufRing (no allocations).

        Use to construct a handler-style consumer before registering the
        buffer ring. The consumer must move-assign the real BufRing into
        place before any add_buffer / buf_base access.
        """
        self.ring_addr = null_ptr[UInt8, MutUntrackedOrigin]()
        self.ring_entries = UInt32(0)
        self.mask = UInt32(0)
        self.bgid = UInt16(0)
        self.buf_base = null_ptr[UInt8, MutUntrackedOrigin]()
        self.buf_size = UInt32(0)
        self.buf_count = UInt32(0)
        self.owns_ring = False

    def __init__(out self, *, deinit move: Self):
        self.ring_addr = move.ring_addr
        self.ring_entries = move.ring_entries
        self.mask = move.mask
        self.bgid = move.bgid
        self.buf_base = move.buf_base
        self.buf_size = move.buf_size
        self.buf_count = move.buf_count
        self.owns_ring = move.owns_ring
        _ = move.owns_ring

    def __deinit__(deinit self):
        """Free the ring memory if this instance owns it."""
        if self.owns_ring:
            self.ring_addr.unsafe_free()

    @always_inline
    def _tail_ptr(self) -> Pointer[UInt16, MutUntrackedOrigin]:
        """Return a pointer to the ring tail (overlaid in slot 0's resv field)."""
        return Pointer[UInt16, MutUntrackedOrigin](
            unsafe_from_address=Int(self.ring_addr) + _IO_URING_BUF_TAIL_OFFSET
        )

    @always_inline
    def _entry_ptr(self, slot: UInt32) -> Pointer[UInt8, MutUntrackedOrigin]:
        """Return a pointer to the start of the ring entry at `slot`."""
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(self.ring_addr) + Int(slot) * _IO_URING_BUF_SIZE
        )

    def _write_entry(
        self,
        slot: UInt32,
        addr: UInt64,
        len: UInt32,
        bid: UInt16,
    ):
        """Write a single io_uring_buf entry into the ring at `slot`.

        struct io_uring_buf { __u64 addr; __u32 len; __u16 bid; __u16 resv; }
        Field offsets verified at compile time by _verify_io_uring_buf_layout.
        """
        var ent = self._entry_ptr(slot)
        # Store addr at _BUF_ADDR_OFFSET (8 bytes)
        Pointer[UInt64, MutUntrackedOrigin](
            unsafe_from_address=Int(ent) + _BUF_ADDR_OFFSET
        )[] = addr
        # len at _BUF_LEN_OFFSET (4 bytes)
        Pointer[UInt32, MutUntrackedOrigin](
            unsafe_from_address=Int(ent) + _BUF_LEN_OFFSET
        )[] = len
        # bid at _BUF_BID_OFFSET (2 bytes)
        Pointer[UInt16, MutUntrackedOrigin](
            unsafe_from_address=Int(ent) + _BUF_BID_OFFSET
        )[] = bid
        # resv at _IO_URING_BUF_TAIL_OFFSET -- DO NOT touch when slot == 0
        # (overlays tail). When slot != 0, leaving it as whatever the
        # previous tail value was is harmless (kernel ignores resv).

    def add_buffer(mut self, buf_id: UInt16):
        """Return a buffer (identified by `buf_id` from a recv CQE) to
        the ring so the kernel can pick it for a future arrival.

        An id at or past `buf_count` names no buffer of this ring and is
        ignored: nothing is written to the ring for it."""
        if UInt32(buf_id) >= self.buf_count:
            return
        var tp = self._tail_ptr()
        var current_tail = tp[]
        var slot = UInt32(current_tail) & self.mask
        var addr = UInt64(Int(self.buf_base)) + UInt64(buf_id) * UInt64(self.buf_size)
        self._write_entry(slot, addr, self.buf_size, buf_id)
        # Plain store on tail. On x86_64 (TSO) this is a store-release
        # because stores are not reordered with each other. NOT safe on
        # weakly-ordered architectures (aarch64) if SQPOLL is ever
        # enabled — a store-release fence would be required. Currently
        # safe because SQPOLL is blocked (comptime assert at qp.mojo:68)
        # and io_uring_enter provides a full memory barrier.
        tp[] = current_tail + UInt16(1)

    def populate_initial(mut self):
        """Fill buf_count ring slots with data buffers and advance tail.

        Only populates slots 0..buf_count-1 (not the full ring_entries),
        so callers whose buf_base has fewer buffers than ring slots
        won't produce out-of-bounds entries. Call once after
        register_buf_ring.
        """
        var tp = self._tail_ptr()
        for i in range(Int(self.buf_count)):
            var bid = UInt16(i)
            var addr = UInt64(Int(self.buf_base)) + UInt64(i) * UInt64(self.buf_size)
            self._write_entry(UInt32(i), addr, self.buf_size, bid)
        tp[] = UInt16(self.buf_count)
