"""Chunked slab of operation states owned by a WatchLoop.

One slab per state type replaces the per-operation heap allocation:
states live in fixed-size chunks that are never moved or shrunk, so
the Completion address handed to the driver stays valid for as long
as the loop exists, and allocating an operation is a free-list pop.

The slab never scans its slots on the hot path. Each state it binds
carries a `_SlotLink` naming the slot; of the two events that make a
slot reclaimable — the completion arriving, the handle letting go —
the second pushes the key onto the loop's settle queue, and the
completion decrements the slab's live counter. The loop's post-tick
sweep decodes the keys it received and calls `settle` on the right
slab for each one, which releases the slot. Only loop destruction
walks every slot.

Loop destruction with a live handle still attached to a slot leaves
the chunks allocated on purpose (see `__deinit__`): the handle keeps
reading the state to report `loop_gone`, and nothing else is left to
free the chunk once the loop is gone. That is a bounded leak paid only
on that misuse, the same bargain `abandon_buffer` already makes.

Not part of the public API.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.watch._callback import _InFlightState, _KIND_BITS, _SlotLink


# Per-slot bookkeeping, kept out of the state so it survives the state's
# destruction.
comptime _ACTIVE = UInt8(1)  # a state lives in the slot


struct _Slab[F: _InFlightState](Movable):
    """Address-stable pool of `F` states with a free list.
    """

    var _chunks: List[Pointer[Self.F, MutUntrackedOrigin]]
    var _chunk_shift: Int
    var _free: List[Int]
    var _flags: List[UInt8]
    var _live: Pointer[Int, MutUntrackedOrigin]
    var _kind: Int
    var _queue: Pointer[List[Int], MutUntrackedOrigin]
    var _leaked: Bool

    def __init__(
        out self,
        chunk_size: Int,
        kind: Int,
        queue: Pointer[List[Int], MutUntrackedOrigin],
    ):
        """Create an empty slab; the first chunk is allocated on demand.

        Args:
            chunk_size: Slots per chunk, rounded up to a power of two.
                        Growth adds one chunk of this size at a time.
            kind: Tag stored in the low `_KIND_BITS` of every key, so
                  the loop can route a queued key back to this slab.
            queue: The loop's settle queue.
        """
        debug_assert(0 <= kind < (1 << _KIND_BITS), "slab kind out of range")
        self._chunks = List[Pointer[Self.F, MutUntrackedOrigin]]()
        var shift = 0
        while (1 << shift) < max(chunk_size, 1):
            shift += 1
        self._chunk_shift = shift
        self._free = List[Int]()
        self._flags = List[UInt8]()
        self._live = unsafe_alloc[Int](1)
        self._live.unsafe_write(0)
        self._kind = kind
        self._queue = queue
        self._leaked = False

    def __init__(out self, *, deinit move: Self):
        self._chunks = move._chunks^
        self._chunk_shift = move._chunk_shift
        self._free = move._free^
        self._flags = move._flags^
        self._live = move._live
        self._kind = move._kind
        self._queue = move._queue
        self._leaked = move._leaked

    def __deinit__(deinit self):
        """Free every chunk unless a handle still points into one.

        `detach_all` must have run first so that every slot is either
        free or marked `loop_gone`. When a slot is marked, the handle
        that owns it will still read it, so the chunks stay allocated;
        the live counter goes with them, since an unfinished state's
        link still names it.
        """
        if self._leaked:
            return
        for chunk in self._chunks:
            chunk.unsafe_free()
        self._live.unsafe_free()

    def _slot(self, index: Int) -> Pointer[Self.F, MutUntrackedOrigin]:
        """Return the pointer to the slot at a global index.

        Args:
            index: Global slot index, chunk-major.
        """
        var chunk = self._chunks[index >> self._chunk_shift]
        return chunk.unsafe_offset(index & ((1 << self._chunk_shift) - 1))

    def _grow(mut self):
        """Add one chunk and push its slots on the free list.

        Existing chunks are untouched, so every pointer handed out so
        far stays valid.
        """
        var chunk_size = 1 << self._chunk_shift
        var base = len(self._chunks) << self._chunk_shift
        self._chunks.append(unsafe_alloc[Self.F](chunk_size))
        var i = base + chunk_size - 1
        while i >= base:
            self._free.append(i)
            self._flags.append(UInt8(0))
            i -= 1

    def alloc(
        mut self, var state: Self.F
    ) -> Pointer[Self.F, MutUntrackedOrigin]:
        """Move a state into a free slot, bind it, and count it live.

        Args:
            state: The freshly built operation state.

        Returns:
            A pointer to the slot, stable until the slab is destroyed.
        """
        if len(self._free) == 0:
            self._grow()
        var index = self._free.pop()
        var ptr = self._slot(index)
        ptr.unsafe_write(state^)
        ptr[].bind(
            _SlotLink(
                (index << _KIND_BITS) | self._kind, self._queue, self._live
            )
        )
        self._flags[index] = _ACTIVE
        self._live[] += 1
        return ptr

    def _release(mut self, index: Int):
        """Destroy the state in a slot and return the slot to the free list.

        Args:
            index: Global index of an active slot nobody owns.
        """
        self._slot(index).unsafe_deinit_pointee()
        self._flags[index] = UInt8(0)
        self._free.append(index)

    def discard(mut self, index: Int):
        """Release a slot whose operation was never handed to the driver.

        The loop allocates a state before it submits the operation, so
        a driver that refuses the submission leaves a state that no
        completion will ever visit and no handle will ever own. This
        undoes the `alloc`: the state is destroyed, the slot returns to
        the free list and the live count is decremented, exactly as if
        the state had never existed. Valid only while nothing has been
        submitted for the slot; anything the kernel could still touch
        must be taken out of the state first.

        Args:
            index: Global index of the slot `alloc` just handed out.
        """
        debug_assert(
            (self._flags[index] & _ACTIVE) != 0, "discard on a free slot"
        )
        self._live[] -= 1
        self._release(index)

    def settle(mut self, index: Int):
        """Release one slot whose key was queued.

        A key is queued exactly once, by the second of the two events,
        so the slot is done and ownerless by the time it gets here. The
        active bit still guards it: the loop's destructor may have
        released it already if the queue outlived a detach.

        Args:
            index: Global index decoded from a settle-queue key.
        """
        if not (self._flags[index] & _ACTIVE):
            return
        var ptr = self._slot(index)
        debug_assert(
            ptr[].is_done() and ptr[].owner_dropped(),
            "settle on a slot that is not reclaimable",
        )
        ptr.unsafe_deinit_pointee()
        self._flags[index] = UInt8(0)
        self._free.append(index)

    def in_flight(self) -> Int:
        """Return how many operations are submitted and not yet done."""
        return self._live[]

    def is_active(self, index: Int) -> Bool:
        """Return True if a state currently lives in slot `index`.

        Args:
            index: Global slot index; out-of-range indices are inactive.
        """
        return index >= 0 and index < len(self._flags) and (
            self._flags[index] & _ACTIVE
        ) != 0

    def active(self) -> Int:
        """Return how many slots hold a state (done or not, owned or not).

        Diagnostic for tests: 0 once every state has been settled.
        """
        var n = 0
        for index in range(len(self._flags)):
            if self._flags[index] & _ACTIVE:
                n += 1
        return n

    def abandon_all(mut self):
        """Ask every unfinished state to give up its kernel-visible memory.

        Called at loop destruction before the driver is torn down.
        """
        for index in range(len(self._flags)):
            if self._flags[index] & _ACTIVE:
                var ptr = self._slot(index)
                if not ptr[].is_done():
                    ptr[].abandon_buffer()

    def detach_all(mut self):
        """Sever every slot from the loop being destroyed.

        Called after the driver is gone, so no callback can fire. Slots
        whose handle was dropped are released. Slots still owned by a
        handle are marked `loop_gone` and the chunks are kept alive for
        that handle; the slab then never frees them.
        """
        for index in range(len(self._flags)):
            if not (self._flags[index] & _ACTIVE):
                continue
            var ptr = self._slot(index)
            if ptr[].owner_dropped():
                self._release(index)
            else:
                ptr[].mark_loop_gone()
                self._leaked = True
        self._live[] = 0
