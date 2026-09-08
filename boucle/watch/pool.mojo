"""`BufferPool` and `LeasedBuffer` — loop-owned buffers for multishot receives.

A `BufferPool` is a handle onto a slab-resident `_PoolState` that owns
`capacity * buffer_size` bytes registered with the driver as one
provided-buffer group. Deliveries hand out `LeasedBuffer`s; a lease
returns its buffer to the group when it drops. When every buffer is
leased the stream ends with ENOBUFS and resumes only after leases return
and the caller re-arms: holding leases is the backpressure lever.

Ownership follows `_callback.mojo` with two refinements. The slot is
released at the sweep after the handle dropped, every lease returned and
every referencing stream detached; `owner_dropped()` reports True only
once all three hold, so loop destruction leaks (rather than frees) a pool
a delivery may still read. And once the loop is gone every handle is
inert: several handles share the state, so none of them may destroy it.
"""

from std.memory import Pointer

from boucle.socle.ptr import null_ptr
from boucle.watch._callback import _InFlightState, _SlotLink
from boucle.watch._shared import _LoopShared


# ===----------------------------------------------------------------------=== #
# _PoolState — internal, slab-owned
# ===----------------------------------------------------------------------=== #


struct _PoolState(_InFlightState):
    """Slab-owned state of one buffer pool.
    """

    var memory: Pointer[UInt8, MutUntrackedOrigin]
    var buffer_size: Int
    var count: Int
    var group_id: UInt16
    var available: Int
    var streams: Int
    var registered: Bool
    var closing: Bool
    var _shared: Pointer[_LoopShared, MutUntrackedOrigin]
    var _abandoned: Bool
    var _queued: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(
        out self,
        memory: Pointer[UInt8, MutUntrackedOrigin],
        buffer_size: Int,
        count: Int,
        group_id: UInt16,
        shared: Pointer[_LoopShared, MutUntrackedOrigin],
    ):
        """Construct a pool state over already-allocated memory.

        Args:
            memory: `count * buffer_size` bytes owned by this state.
            buffer_size: Bytes per buffer.
            count: Number of buffers (a power of two).
            group_id: The driver group id the loop assigned.
            shared: The loop's shared box.
        """
        self.memory = memory
        self.buffer_size = buffer_size
        self.count = count
        self.group_id = group_id
        self.available = count
        self.streams = 0
        self.registered = False
        self.closing = False
        self._shared = shared
        self._abandoned = False
        self._queued = False
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        self.memory = move.memory
        self.buffer_size = move.buffer_size
        self.count = move.count
        self.group_id = move.group_id
        self.available = move.available
        self.streams = move.streams
        self.registered = move.registered
        self.closing = move.closing
        self._shared = move._shared
        self._abandoned = move._abandoned
        self._queued = move._queued
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def __deinit__(deinit self):
        """Unregister the driver group while the driver lives, then free the memory.

        Only runs for a pool nothing can reach any more (see
        `owner_dropped`), so freeing is safe. The loop's sweep normally
        calls `release_group` first, so this is a fallback; the loop's
        destructor clears `driver_alive` before it tears the driver down
        and detaches the pool slab only afterwards, so a pool released
        there skips the unregister call: the driver already dropped its
        groups on the way out, and there is nothing left to talk to.
        Memory abandoned at loop destruction (`abandon_buffer`) is
        leaked, never freed.
        """
        _ = self.release_group()
        if not self._abandoned:
            self.memory.unsafe_free()

    def release_group(mut self) -> Bool:
        """Unregister the driver group, once, and say whether its id may be reused.

        Returns:
            True when the driver holds no group under this id any more:
            the group was never registered, or the unregister succeeded.
            False when the driver is gone or the unregister raised, in
            which case the loop must not hand the id to another pool.
        """
        if not self.registered:
            return True
        self.registered = False
        if not self._shared[].driver_alive:
            return False
        try:
            self._shared[].driver[].unregister_buffer_group(self.group_id)
            return True
        except:
            return False

    def holds(self, buf_id: UInt16) -> Bool:
        """Return True if `buf_id` names a buffer of this pool.

        Buffer ids come from completion flags the driver decoded; one at
        or past `count` is never dereferenced.

        Args:
            buf_id: A buffer id from a delivery.
        """
        return Int(buf_id) < self.count

    def buffer_ptr(self, buf_id: UInt16) -> Pointer[UInt8, MutUntrackedOrigin]:
        """Return the start of buffer `buf_id`, or null for an id past the pool.

        Args:
            buf_id: A buffer id from a delivery.

        Returns:
            A pointer to the first byte of that buffer, or a null
            pointer when `buf_id` is not below `count`. Abandoned
            memory is still addressed: it is leaked, not freed.
        """
        if not self.holds(buf_id):
            return null_ptr[UInt8, MutUntrackedOrigin]()
        return self.memory.unsafe_offset(Int(buf_id) * self.buffer_size)

    def abandon_buffer(mut self):
        """Leak the buffer memory when a stream still selects from it.

        Called on every unfinished pool when the WatchLoop is destroyed,
        before the driver is torn down. A pool with `streams > 0` may
        still be the target of an armed multishot receive: on io_uring
        the kernel picks a buffer from the group and writes into it, and
        closing the ring cancels that request asynchronously without
        waiting for the write to stop. The destructor then releases the
        orphaned stream, which detaches the pool, which may make the
        pool itself reclaimable in the same pass — and `__deinit__` would
        free memory the kernel still writes into. Marking the pool
        `_abandoned` makes `__deinit__` skip the free, so the allocation
        is leaked on purpose: the same bounded cost recv/send buffers
        pay. The pointer is kept: a leased buffer is out of the ring, so
        the kernel can only write un-leased ones and a `Datagram` held
        across the destruction keeps reading its bytes.

        A pool with no stream but leases out keeps its memory: no kernel
        request selects from it, and the leases keep the state alive
        until they return. `registered` is left alone: the loop clears
        `driver_alive` before tearing the driver down and detaches the
        pool slab afterwards, so `__deinit__` skips the unregister call
        either way.
        """
        if self.streams > 0:
            self._abandoned = True

    def lease_taken(mut self):
        """Record that a delivery took one buffer out of the pool."""
        self.available -= 1

    def return_lease(mut self, buf_id: UInt16):
        """Hand a leased buffer back to the driver group.

        A no-op once the loop is gone: the memory stays with the leaked
        chunks and nothing is left to return it to. Also a no-op for an
        id past the pool, which no delivery ever leased.

        Args:
            buf_id: The buffer a `LeasedBuffer` held.
        """
        if self._loop_gone or not self.holds(buf_id):
            return
        self.available += 1
        if self._shared[].driver_alive:
            self._shared[].driver[].return_buffer(self.group_id, buf_id)
        self._maybe_settle()

    def recycle(self, buf_id: UInt16):
        """Return a buffer a dropped stream never leased (post-drop delivery).

        The buffer was taken by the driver but never counted out of
        `available`, so only the driver side is undone. An id past the
        pool is ignored: the buffer it names is leaked, never touched.

        Args:
            buf_id: The buffer id from the completion flags.
        """
        if self._loop_gone or not self._shared[].driver_alive:
            return
        if not self.holds(buf_id):
            return
        self._shared[].driver[].return_buffer(self.group_id, buf_id)

    def attach_stream(mut self):
        """Count a stream that will select from this pool."""
        self.streams += 1

    def detach_stream(mut self):
        """Drop a stream reference; the last one may make the pool reclaimable."""
        self.streams -= 1
        self._maybe_settle()

    def _maybe_settle(mut self):
        """Queue the slot for release once nothing can reach the pool any more.

        A no-op once the loop is gone: the settle queue it would push to
        no longer exists, and a stream detaching at that point must not
        reach it.
        """
        if self._loop_gone or self._queued or not self._owner_dropped:
            return
        if self.available == self.count and self.streams == 0:
            self._queued = True
            self.notify_done()

    def is_done(self) -> Bool:
        """Return True when no lease is out and no stream references the pool."""
        return self.available == self.count and self.streams == 0

    def owner_dropped(self) -> Bool:
        """Return True once the handle dropped AND nothing else can reach the state.

        Weaker than the flag on purpose: a pool whose handle is gone but
        whose buffers a lease still views must be leaked, not freed, when
        the loop is destroyed.
        """
        return self._owner_dropped and self.is_done()

    def loop_gone(self) -> Bool:
        """Return True if the loop was destroyed with this pool in flight."""
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the loop is gone; every handle becomes inert."""
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Record the slot this state lives in and the queue to notify.
        """
        self._link = link

    def notify_done(self):
        """Stop counting the pool live and queue its slot (owner already gone)."""
        self._link.completed(True)

    def mark_owner_dropped(mut self):
        """Record that the `BufferPool` handle let go; settle if nothing else holds on."""
        self._owner_dropped = True
        self.closing = True
        self._maybe_settle()


# ===----------------------------------------------------------------------=== #
# LeasedBuffer — one buffer handed out by a delivery
# ===----------------------------------------------------------------------=== #


struct LeasedBuffer(Movable):
    """One buffer handed out by a delivery; returns itself to the pool on drop.

    When every buffer is leased the stream ends with ENOBUFS and resumes
    only after leases return and the caller re-arms: holding leases is
    the backpressure lever. Inert once the loop is gone.
    """

    var _pool: Pointer[_PoolState, MutUntrackedOrigin]
    var _id: UInt16

    def __init__(
        out self, pool: Pointer[_PoolState, MutUntrackedOrigin], id: UInt16
    ):
        """Lease buffer `id` of `pool`; the caller already counted it out.

        Args:
            pool: The slab-owned pool state.
            id: The buffer id.
        """
        self._pool = pool
        self._id = id

    def __init__(out self, *, deinit move: Self):
        self._pool = move._pool
        self._id = move._id

    def __deinit__(deinit self):
        """Return the buffer to the pool (no-op once the loop is gone)."""
        self._pool[].return_lease(self._id)

    def bytes(ref self) -> Span[UInt8, MutUntrackedOrigin]:
        """View the whole buffer, delivery header included.

        Returns:
            A span of `buffer_size` bytes, or an empty span when the id
            names no buffer of the pool.
        """
        var base = self._pool[].buffer_ptr(self._id)
        if Int(base) == 0:
            return Span[UInt8, MutUntrackedOrigin]()
        return Span[UInt8, MutUntrackedOrigin](
            unsafe_ptr=base, length=self._pool[].buffer_size
        )

    def id(self) -> UInt16:
        """Return the buffer id within its pool."""
        return self._id


# ===----------------------------------------------------------------------=== #
# BufferPool — handle returned by WatchLoop.buffer_pool
# ===----------------------------------------------------------------------=== #


struct BufferPool(Movable):
    """Handle to a loop-owned set of fixed-size buffers for multishot receives.

    The kernel (io_uring) or the loop (epoll) picks a buffer from the pool
    for each delivery. Dropping the handle marks the pool closing; the
    loop releases the pool (driver group unregistered, memory freed) at
    the sweep after every lease has returned and every stream using it
    has ended. Once the loop is gone the handle is inert.
    """

    var _state: Pointer[_PoolState, MutUntrackedOrigin]

    def __init__(out self, state: Pointer[_PoolState, MutUntrackedOrigin]):
        """Wrap a slab-owned pool state.

        Args:
            state: Pointer to the `_PoolState`.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        self._state = move._state

    def __deinit__(deinit self):
        """Hand the pool over to the loop, or do nothing if the loop is gone."""
        if not self._state[]._loop_gone:
            self._state[].mark_owner_dropped()

    def capacity(self) -> Int:
        """Return the number of buffers (count rounded up to a power of two)."""
        return self._state[].count

    def available(self) -> Int:
        """Return how many buffers are neither queued nor leased."""
        return self._state[].available

    def buffer_size(self) -> Int:
        """Return the size of each buffer in bytes."""
        return self._state[].buffer_size
