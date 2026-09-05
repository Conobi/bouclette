"""Linux epoll-based completion driver for the IoDriver trait.

Emulates io_uring-style completion semantics over epoll: each
operation method registers interest with epoll and stores a per-operation
wrapper (_EpollOp) in a slab pool. The slot index and a per-slot
generation counter are packed into epoll_event.data. When epoll_wait
fires, the slot is recovered, checked for staleness, the non-blocking
I/O is performed, and the Completion callback is invoked -- all within
tick(). Operations that complete without epoll (nop, cancel,
immediate connect) go through a deferred-ready queue drained at
the start of each tick().
"""

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.socle.linux.raw import (
    syscall,
    epoll_event,
    __NR_epoll_ctl,
    __NR_dup,
    __NR_close,
    __NR_fcntl,
    __NR_recvfrom,
    __NR_sendto,
    __NR_accept4,
    __NR_recvmsg,
    __NR_sendmsg,
    __NR_connect,
    __NR_getsockopt,
    __kernel_timespec,
    EPOLLIN,
    EPOLLOUT,
    EPOLLET,
    EPOLL_CTL_ADD,
    EPOLL_CTL_DEL,
    EAGAIN,
    EEXIST,
    EINPROGRESS,
    ECANCELED,
    ENOENT,
    ETIME,
    F_GETFL,
    F_SETFL,
    MSG_NOSIGNAL,
    O_CLOEXEC,
    O_NONBLOCK,
    SOL_SOCKET,
    SO_ERROR,
)
from boucle.socle.linux.epoll.syscalls import epoll_create, epoll_wait
from boucle.socle.linux.fd import close_unchecked
from boucle.socle.linux.errno import _check_for_errors, unsafe_decode_result
from boucle.socle.ptr import null_ptr
from boucle.proactor.completion import Completion
from boucle.handle import RawHandle
from boucle.drivers.driver import IoDriver
from boucle.drivers.backend import Backend
from boucle.drivers.feature import DriverFeature


# ── Constants ──────────────────────────────────────────────────────────────────

comptime _CLOCK_MONOTONIC = Int32(1)

# Slots the op pool starts with. It doubles on demand from there.
comptime _INITIAL_POOL_CAPACITY = 64

# Hard ceiling on pool slots: the slot index travels in the low 32 bits
# of epoll_event.data, so no more than 2^32 slots can be addressed.
comptime _MAX_POOL_CAPACITY = 1 << 32


# ── Helper: monotonic clock ───────────────────────────────────────────────────


@always_inline
def _monotonic_ns() -> Int64:
    """Read CLOCK_MONOTONIC via libc clock_gettime (VDSO, no kernel entry)."""
    var ts = __kernel_timespec(0, 0)
    var res = external_call["clock_gettime", Int32](
        _CLOCK_MONOTONIC,
        Pointer(to=ts).unsafe_bitcast[__kernel_timespec](),
    )
    debug_assert(res == 0, "clock_gettime(CLOCK_MONOTONIC) failed")
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec


# ── Helper: epoll_wait timeout ────────────────────────────────────────────────


def _epoll_wait_timeout_ms(
    *, wait: Bool, has_deadline: Bool, remaining_ns: Int64
) -> Int32:
    """Compute the epoll_wait timeout for one tick().

    Rules:
        - not wait: 0, whether or not a timer is armed -- the caller has
          work to process, so never block.
        - wait, no timer armed: -1, block until an fd becomes ready.
        - wait, timer armed: milliseconds until the earliest deadline,
          in [1, Int32.MAX]. A deadline already reached gives 0. A
          positive remainder is rounded UP to whole milliseconds (so a
          sub-millisecond remainder gives 1 and epoll never wakes
          before the deadline, which would busy-spin), and anything
          beyond Int32.MAX milliseconds (~24.8 days) clamps to
          Int32.MAX; a plain Int32 cast would wrap negative, which
          epoll_wait reads as "block forever".

    Args:
        wait: Whether this tick may block at all.
        has_deadline: Whether at least one timer is armed.
        remaining_ns: Nanoseconds until the earliest deadline; only
                      read when has_deadline is True.

    Returns:
        The timeout to pass to epoll_wait: -1, 0 or a positive count
        of milliseconds no greater than Int32.MAX.
    """
    if not wait:
        return 0
    if not has_deadline:
        return -1
    if remaining_ns <= 0:
        return 0
    comptime NS_PER_MS = Int64(1_000_000)
    var longest_ns = Int32.MAX.cast[DType.int64]() * NS_PER_MS
    if remaining_ns >= longest_ns:
        return Int32.MAX
    var whole_ms_rounded_up = (remaining_ns + NS_PER_MS - 1) // NS_PER_MS
    return whole_ms_rounded_up.cast[DType.int32]()


# ── Internal data structures ──────────────────────────────────────────────────


@fieldwise_init
struct _OpKind(TrivialRegisterPassable):
    """Operation kind tag for _EpollOp dispatch."""

    comptime NOP = Self(0)
    comptime CONNECT = Self(1)
    comptime ACCEPT = Self(2)
    comptime RECV = Self(3)
    comptime SEND = Self(4)
    comptime RECVMSG = Self(5)
    comptime SENDMSG = Self(6)
    comptime TIMEOUT = Self(7)
    comptime CANCEL = Self(8)

    var id: UInt8

    @always_inline("nodebug")
    def __is__(self, rhs: Self) -> Bool:
        """Pattern matching support."""
        return self.id == rhs.id

    @always_inline("nodebug")
    def __isnot__(self, rhs: Self) -> Bool:
        """Pattern matching support."""
        return self.id != rhs.id


struct _EpollOp(ImplicitlyCopyable, Movable):
    """Per-operation wrapper stored in the slab pool.

    Holds everything _dispatch_op needs to perform the non-blocking
    I/O and fire the Completion callback. `generation` is bumped each
    time the slot is freed so a stale epoll event (one whose op was
    cancelled or completed earlier in the same batch) is recognised
    and skipped instead of dispatching a freed or re-used slot.
    """

    var kind: _OpKind
    var fd: Int32
    var dup_fd: Int32
    var buf: UInt64
    var len: UInt32
    var addr: UInt64
    var addr_len: UInt64
    var msg: UInt64
    var completion: Pointer[Completion, MutUntrackedOrigin]
    var deadline_ns: Int64
    var pool_index: Int
    var generation: UInt32
    var active: Bool

    def __init__(out self, *, pool_index: Int):
        """Create an inactive op slot at the given pool index."""
        self.kind = _OpKind.NOP
        self.fd = Int32(-1)
        self.dup_fd = Int32(-1)
        self.buf = UInt64(0)
        self.len = UInt32(0)
        self.addr = UInt64(0)
        self.addr_len = UInt64(0)
        self.msg = UInt64(0)
        self.completion = null_ptr[Completion, MutUntrackedOrigin]()
        self.deadline_ns = Int64(-1)
        self.pool_index = pool_index
        self.generation = UInt32(0)
        self.active = False


@always_inline
def _event_data(op: Pointer[_EpollOp, MutUntrackedOrigin]) -> UInt64:
    """Pack an op's slot index (low 32 bits) and generation (high 32 bits).

    This is the value stored in epoll_event.data; tick() unpacks it and
    only dispatches when the slot is still active with the same
    generation.

    Args:
        op: Pointer to the op whose identity is being packed.

    Returns:
        The 64-bit epoll user data for this op.
    """
    return (UInt64(op[].generation) << 32) | UInt64(op[].pool_index)


@fieldwise_init
struct _ReadyEntry(ImplicitlyCopyable, Movable):
    """Deferred completion for operations that complete without epoll."""

    var completion: Pointer[Completion, MutUntrackedOrigin]
    var result: Int
    var flags: UInt32


@fieldwise_init
struct _TimerEntry(ImplicitlyCopyable, Movable):
    """Min-heap element for userspace timers."""

    var deadline_ns: Int64
    var pool_index: Int


# ── Timer min-heap ────────────────────────────────────────────────────────────


struct _TimerHeap(Movable):
    """Simple min-heap of _TimerEntry sorted by deadline_ns."""

    var _entries: List[_TimerEntry]

    def __init__(out self):
        """Create an empty timer heap."""
        self._entries = List[_TimerEntry]()

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._entries = move._entries^

    def push(mut self, entry: _TimerEntry):
        """Append entry and sift up to restore heap order."""
        self._entries.append(entry)
        self._sift_up(len(self._entries) - 1)

    def peek_deadline(self) -> Int64:
        """Return the minimum deadline, or Int64.MAX if empty."""
        if len(self._entries) == 0:
            return Int64.MAX
        return self._entries[0].deadline_ns

    def pop(mut self) -> _TimerEntry:
        """Remove and return the minimum entry, restoring heap order."""
        var result = self._entries[0]
        var last_idx = len(self._entries) - 1
        if last_idx > 0:
            self._entries[0] = self._entries[last_idx]
        _ = self._entries.pop()
        if len(self._entries) > 0:
            self._sift_down(0)
        return result

    def remove_by_pool_index(mut self, index: Int) -> Bool:
        """Remove the entry with the given pool_index (linear scan).

        Args:
            index: The pool index to search for.

        Returns:
            True if found and removed, False otherwise.
        """
        for i in range(len(self._entries)):
            if self._entries[i].pool_index == index:
                var last_idx = len(self._entries) - 1
                if i != last_idx:
                    self._entries[i] = self._entries[last_idx]
                _ = self._entries.pop()
                if i < len(self._entries):
                    self._sift_down(i)
                    self._sift_up(i)
                return True
        return False

    def _sift_up(mut self, idx: Int):
        """Restore heap order by moving element at idx upward."""
        var i = idx
        while i > 0:
            var parent = (i - 1) // 2
            if self._entries[i].deadline_ns < self._entries[parent].deadline_ns:
                var tmp = self._entries[i]
                self._entries[i] = self._entries[parent]
                self._entries[parent] = tmp
                i = parent
            else:
                break

    def _sift_down(mut self, idx: Int):
        """Restore heap order by moving element at idx downward."""
        var n = len(self._entries)
        var i = idx
        while True:
            var smallest = i
            var left = 2 * i + 1
            var right = 2 * i + 2
            if (
                left < n
                and self._entries[left].deadline_ns
                < self._entries[smallest].deadline_ns
            ):
                smallest = left
            if (
                right < n
                and self._entries[right].deadline_ns
                < self._entries[smallest].deadline_ns
            ):
                smallest = right
            if smallest == i:
                break
            var tmp = self._entries[i]
            self._entries[i] = self._entries[smallest]
            self._entries[smallest] = tmp
            i = smallest


# ── Op slab pool ──────────────────────────────────────────────────────────────


struct _OpPool(Movable):
    """Growable slab allocator for _EpollOp instances.

    alloc() pops a free slot and returns a pointer to it; free() returns
    the slot to the pool. When no slot is free the slot array is
    reallocated at double its size and every live slot is copied over,
    so there is no fixed limit on in-flight ops (matching io_uring,
    where the kernel holds them) short of the 2^32 slots that the
    32-bit index packed into epoll_event.data can address.

    Reallocation moves slot addresses, which is sound because nothing
    in the driver retains a slot pointer across a call that can
    allocate: tick() re-derives the pointer from the event's index for
    every event, _dispatch_op and the timer path copy what they need
    and free the slot BEFORE firing the callback (the only place user
    code, and hence a nested operation method, can run), cancel scans
    without allocating, and each operation method fills its freshly
    allocated slot and registers it without allocating again. Everything that
    outlives a call refers to slots by index (timer heap, epoll data),
    never by address.
    """

    var _slots: Pointer[_EpollOp, MutUntrackedOrigin]
    var _free: List[Int]
    var _capacity: Int

    def __init__(out self, capacity: Int):
        """Create a pool with the given number of initial slots.

        Args:
            capacity: Number of op slots to allocate up front; the pool
                      doubles from here whenever it runs out.
        """
        self._capacity = capacity
        self._slots = unsafe_alloc[_EpollOp](capacity)
        self._free = List[Int](capacity=capacity)
        for i in range(capacity):
            self._slots.unsafe_offset(i).unsafe_write(
                _EpollOp(pool_index=i)
            )
            self._free.append(i)

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._slots = move._slots
        self._free = move._free^
        self._capacity = move._capacity

    def __deinit__(deinit self):
        """Free the slot array."""
        self._slots.unsafe_free()

    def alloc(mut self) raises -> Pointer[_EpollOp, MutUntrackedOrigin]:
        """Allocate a slot, growing the pool if none is free.

        Returns a pointer to the allocated _EpollOp. The caller must set
        all relevant fields before registering with epoll and must not
        keep the pointer across another alloc(), which may move the
        slot array (see the struct docstring).

        Raises:
            If the pool already holds 2^32 slots, the most the 32-bit
            slot index in epoll_event.data can address.
        """
        if len(self._free) == 0:
            self._grow()
        var idx = self._free.pop()
        self._slots[unsafe_offset=idx].active = True
        return self._slots.unsafe_offset(idx)

    def _grow(mut self) raises:
        """Double the slot array, preserving every existing slot.

        Live and free slots alike are copied to the new array with
        their pool_index, generation and active flag intact, so packed
        epoll event data and timer heap entries stay valid. The added
        slots are pushed onto the free list and the old array is
        released.

        Raises:
            If the pool is already at the 2^32-slot ceiling.
        """
        if self._capacity >= _MAX_POOL_CAPACITY:
            raise "op pool exhausted (2^32 slot limit of epoll_event.data)"
        var new_capacity = min(self._capacity * 2, _MAX_POOL_CAPACITY)
        var new_slots = unsafe_alloc[_EpollOp](new_capacity)
        for i in range(self._capacity):
            new_slots.unsafe_offset(i).unsafe_write(
                self._slots[unsafe_offset=i]
            )
        for i in range(self._capacity, new_capacity):
            new_slots.unsafe_offset(i).unsafe_write(_EpollOp(pool_index=i))
            self._free.append(i)
        self._slots.unsafe_free()
        self._slots = new_slots
        self._capacity = new_capacity

    def free(mut self, index: Int):
        """Return a slot to the pool and bump its generation.

        Freeing a slot that is not active is a double free; it is
        rejected by debug_assert so the free list can never hold the
        same index twice.

        Args:
            index: The pool index of the slot to free.
        """
        debug_assert(
            self._slots[unsafe_offset=index].active,
            "double free of op pool slot",
        )
        self._slots[unsafe_offset=index].active = False
        self._slots[unsafe_offset=index].generation += 1
        self._free.append(index)

    def free_count(self) -> Int:
        """Return the number of free slots in the current array."""
        return len(self._free)

    def capacity(self) -> Int:
        """Return the number of slots in the current array, free or not."""
        return self._capacity

    def slot_ptr(self, index: Int) -> Pointer[_EpollOp, MutUntrackedOrigin]:
        """Return a pointer to the slot at the given index.

        Args:
            index: The pool index of the slot.

        Returns:
            Pointer to the _EpollOp at the given index.
        """
        return self._slots.unsafe_offset(index)


# ── Heap-boxed mutable state ─────────────────────────────────────────────────


struct _DriverState(Movable):
    """All driver state that a Completion callback may mutate.

    Callbacks run inside tick(), which holds `mut self` on the driver,
    yet they may legally call operation methods on that same driver through a
    raw pointer. Because `mut` grants exclusive access, the compiler
    may keep the driver's inline fields (e.g. a List length) in
    registers across the callback call and never observe the
    callback's writes. Boxing this state on the heap forces every
    access to go through a loaded pointer, so post-callback reads see
    memory as it really is.
    """

    var pool: _OpPool
    var timers: _TimerHeap
    var ready: List[_ReadyEntry]

    def __init__(out self, *, capacity: Int):
        """Create the pool, an empty timer heap and an empty ready queue.

        Args:
            capacity: Number of op slots in the pool.
        """
        self.pool = _OpPool(capacity=capacity)
        self.timers = _TimerHeap()
        self.ready = List[_ReadyEntry]()

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.pool = move.pool^
        self.timers = move.timers^
        self.ready = move.ready^


# ── EpollCompletionDriver ────────────────────────────────────────────────────


struct EpollCompletionDriver(IoDriver):
    """IoDriver that emulates completion semantics over Linux epoll.

    Each operation method allocates an _EpollOp from a slab pool,
    stores the operation kind, buffer pointers, and Completion pointer.
    The slot index and generation go into epoll_event.data. On tick(),
    epoll_wait() fires, the op is recovered and validated, the
    non-blocking I/O is performed, and the Completion callback is
    invoked.

    Operations that complete without epoll (nop, cancel, immediate
    connect result) enqueue a _ReadyEntry. At the start of tick(),
    the ready queue is drained before calling epoll_wait(). ALL
    callbacks fire during tick() -- never during operation methods.

    Callbacks may call operation methods on this driver; see
    _DriverState for why the mutable state is heap-boxed to make
    that sound.
    """

    var _epfd: Int32
    var _events: Pointer[epoll_event, MutUntrackedOrigin]
    var _max_events: Int32
    var _state: Pointer[_DriverState, MutUntrackedOrigin]

    def __init__(out self, *, capacity: Int = 64) raises:
        """Create an epoll completion driver with the given capacity hint.

        The op pool is independent of `capacity`: it starts with 64
        slots and doubles whenever a submit finds none free, so the
        number of in-flight ops is unbounded (up to the 2^32 slots the
        epoll event data can index), as with io_uring. `capacity`
        only bounds how many events one epoll_wait call, and so one
        tick(), can dispatch.

        Args:
            capacity: Maximum events per epoll_wait call (default 64).
        """
        self._epfd = epoll_create()
        self._max_events = Int32(capacity)
        self._events = unsafe_alloc[epoll_event](capacity)
        self._state = unsafe_alloc[_DriverState](1)
        self._state.unsafe_write(
            _DriverState(capacity=_INITIAL_POOL_CAPACITY)
        )

    def __init__(out self, *, deinit move: Self):
        """Move constructor. Copies the state pointer for address stability."""
        self._epfd = move._epfd
        self._events = move._events
        self._max_events = move._max_events
        self._state = move._state

    def __deinit__(deinit self):
        """Release all resources: dup'd fds, epoll fd, event buffer, state."""
        # Close dup'd fds for active ops.
        for i in range(self._state[].pool.capacity()):
            var op = self._state[].pool.slot_ptr(i)
            if op[].active and op[].dup_fd != Int32(-1):
                close_unchecked(unsafe_fd=op[].dup_fd)
        # Close the epoll instance.
        close_unchecked(unsafe_fd=self._epfd)
        # Free the event buffer.
        self._events.unsafe_free()
        # Destroy the boxed state (pool, timers, ready queue) and free it.
        self._state.unsafe_deinit_pointee()
        self._state.unsafe_free()

    def backend(self) -> Backend:
        """Return Backend.EPOLL."""
        return Backend.EPOLL

    def supports(self, feature: DriverFeature) -> Bool:
        """Return True for every feature: this driver emulates them all.

        Multishot recvmsg and buffer groups are userspace loops over
        `recvmsg` and a free list; a bounded wait is the epoll_wait
        timeout. Nothing depends on the kernel version.

        Args:
            feature: The capability to query.

        Returns:
            True.
        """
        return True

    def tick(mut self, wait: Bool) raises -> Int:
        """Drain ready queue, poll epoll, fire expired timers.

        All Completion callbacks fire here -- never during operation methods.

        Callbacks may themselves call operation methods on this driver.
        Ready entries they append (nop, cancel, immediate connect) are
        kept and fire on the NEXT tick, mirroring io_uring where an
        operation queued from a callback is not entered until the
        following tick. Only the entries present when the drain started fire in
        this tick, so a callback that re-submits on every completion
        cannot spin the drain forever. Epoll events whose op was
        cancelled or completed by an earlier callback in the same
        batch are recognised by their stale generation and skipped.

        Args:
            wait: If True, block until at least one event or timer.
                  If False, return immediately after dispatching any
                  already-available events.

        Returns:
            The number of dispatched completions.
        """
        var dispatched = 0

        # 1. Drain the deferred-ready queue. The bound is fixed before
        #    firing; entries appended by callbacks land past it and are
        #    preserved for the next tick instead of being cleared away.
        #    Each entry is copied out first because a callback may
        #    append and reallocate the queue's buffer.
        var ready_count = len(self._state[].ready)
        for i in range(ready_count):
            var entry = self._state[].ready[i]
            entry.completion[].fire(entry.result, entry.flags)
            dispatched += 1
        self._drop_ready_prefix(ready_count)

        # 2. Compute epoll timeout from timer heap.
        # If we already dispatched from the ready queue, don't block —
        # the caller has work to process.
        var effective_wait = wait and dispatched == 0
        var next_deadline = self._state[].timers.peek_deadline()
        var has_deadline = next_deadline != Int64.MAX
        var remaining_ns = Int64(0)
        if has_deadline:
            remaining_ns = next_deadline - _monotonic_ns()
        var timeout_ms = _epoll_wait_timeout_ms(
            wait=effective_wait,
            has_deadline=has_deadline,
            remaining_ns=remaining_ns,
        )

        # 3. epoll_wait.
        var n = epoll_wait(
            self._epfd,
            self._events,
            max_events=self._max_events,
            timeout=timeout_ms,
        )

        # 4. Dispatch epoll events, skipping stale ones.
        for i in range(Int(n)):
            var data = self._events[unsafe_offset=i].data()
            var index = Int(data & 0xFFFF_FFFF)
            var generation = UInt32(data >> 32)
            var op = self._state[].pool.slot_ptr(index)
            if not op[].active or op[].generation != generation:
                # The op behind this event was cancelled (or completed
                # and its slot re-used) by a callback earlier in this
                # batch; its completion has already been accounted for.
                continue
            dispatched += self._dispatch_op(op)

        # 5. Fire expired timers. Free the slot BEFORE firing so a
        #    callback that cancels this very completion sees "not found"
        #    rather than freeing the slot a second time.
        var now_ns = _monotonic_ns()
        while self._state[].timers.peek_deadline() <= now_ns:
            var entry = self._state[].timers.pop()
            var completion = self._state[].pool.slot_ptr(
                entry.pool_index
            )[].completion
            self._state[].pool.free(entry.pool_index)
            completion[].fire(-Int(ETIME), UInt32(0))
            dispatched += 1

        return dispatched

    def _drop_ready_prefix(mut self, count: Int):
        """Remove the first `count` entries of the ready queue.

        Entries appended past `count` by callbacks during the drain are
        kept, in order, so they fire on the next tick. The common case
        (nothing appended) is a plain clear with no allocation.

        Args:
            count: Number of leading entries that have already fired.
        """
        var total = len(self._state[].ready)
        if total <= count:
            self._state[].ready.clear()
            return
        var remaining = List[_ReadyEntry](capacity=total - count)
        for i in range(count, total):
            remaining.append(self._state[].ready[i])
        self._state[].ready = remaining^

    def _epoll_remove(self, fd: Int32):
        """Remove fd from the epoll interest list, ignoring errors.

        Used when an op completes or is cancelled. ENOENT (fd already
        gone, e.g. closed by the user) is harmless here.

        Args:
            fd: The tracked fd (the original or its dup) to remove.
        """
        var dummy_ev = epoll_event()
        _ = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
            self._epfd,
            Int32(EPOLL_CTL_DEL),
            fd,
            Pointer(to=dummy_ev),
        )

    def _dispatch_op(
        mut self, op: Pointer[_EpollOp, MutUntrackedOrigin]
    ) -> Int:
        """Perform non-blocking I/O for the given op and fire its callback.

        Called from tick() when epoll_wait returns a live event for this
        _EpollOp. The actual I/O syscall happens here (not during
        operation methods). If the syscall reports EAGAIN (spurious wake-up, or
        another op on a dup of the same fd consumed the readiness), the
        op stays registered and nothing fires.

        The slot is detached from epoll, released to the pool and its
        dup'd fd closed BEFORE the callback fires, so a callback that
        cancels this same completion sees "not found" and a callback
        that submits a new op may legitimately re-use the slot.

        Args:
            op: Pointer to the live _EpollOp recovered from epoll_event.data.

        Returns:
            1 if a completion was dispatched, 0 if EAGAIN (op stays pending).
        """
        var kind = op[].kind
        var result = Int(0)

        if kind is _OpKind.RECV:
            var res = syscall[__NR_recvfrom, Scalar[DType.int64]](
                op[].fd,
                Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].buf)
                ),
                UInt(op[].len),
                UInt(0),
                UInt(0),
                UInt(0),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return 0
            result = Int(res)

        elif kind is _OpKind.SEND:
            var res = syscall[__NR_sendto, Scalar[DType.int64]](
                op[].fd,
                Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].buf)
                ),
                UInt(op[].len),
                UInt(MSG_NOSIGNAL),
                UInt(0),
                UInt(0),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return 0
            result = Int(res)

        elif kind is _OpKind.CONNECT:
            var optval = Int32(0)
            var optlen = Int32(4)
            var gso_res = syscall[__NR_getsockopt, Scalar[DType.int64]](
                op[].fd,
                Int32(SOL_SOCKET),
                Int32(SO_ERROR),
                Pointer(to=optval),
                Pointer(to=optlen),
            )
            if gso_res < 0:
                result = Int(gso_res)
            elif optval == 0:
                result = 0
            else:
                result = -Int(optval)

        elif kind is _OpKind.ACCEPT:
            var res = syscall[__NR_accept4, Scalar[DType.int64]](
                op[].fd,
                UInt(0),
                UInt(0),
                Int32(O_CLOEXEC | O_NONBLOCK),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                # Another accept on (a dup of) this listener took the
                # connection; stay armed for the next one.
                return 0
            result = Int(res)

        elif kind is _OpKind.RECVMSG:
            var res = syscall[__NR_recvmsg, Scalar[DType.int64]](
                op[].fd,
                Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].msg)
                ),
                Int32(0),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return 0
            result = Int(res)

        elif kind is _OpKind.SENDMSG:
            var res = syscall[__NR_sendmsg, Scalar[DType.int64]](
                op[].fd,
                Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].msg)
                ),
                Int32(MSG_NOSIGNAL),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return 0
            result = Int(res)

        else:
            debug_assert(False, "unexpected op kind in _dispatch_op")

        # Copy what the callback needs, then release everything before
        # firing. Remove the fd from epoll first: a stale registration
        # would otherwise wake on the next data with a dead slot index.
        var completion = op[].completion
        var dup_fd = op[].dup_fd
        var tracked_fd = op[].fd
        if dup_fd != Int32(-1):
            tracked_fd = dup_fd
        self._epoll_remove(tracked_fd)
        if dup_fd != Int32(-1):
            close_unchecked(unsafe_fd=dup_fd)
        self._state[].pool.free(op[].pool_index)

        completion[].fire(result, UInt32(0))
        return 1

    def _register_op(
        mut self,
        op: Pointer[_EpollOp, MutUntrackedOrigin],
        events: UInt32,
    ) raises:
        """Register the op's fd with epoll for the given events.

        If the fd is already registered (EEXIST), dup the fd and
        register the duplicate instead. The dup'd fd is stored in
        op[].dup_fd and closed after I/O completion.

        If registration fails (e.g. EPERM for a file that cannot be
        polled, or dup failure), the slot is returned to the pool and
        any dup'd fd is closed before the error propagates, so a
        failed submit leaves the driver exactly as it was.

        Args:
            op: Pointer to the freshly allocated _EpollOp to register.
            events: Epoll event flags (EPOLLIN and/or EPOLLOUT).
                    EPOLLET is added automatically.

        Raises:
            If epoll_ctl or dup fails.
        """
        try:
            self._add_to_epoll(op, events)
        except e:
            if op[].dup_fd != Int32(-1):
                close_unchecked(unsafe_fd=op[].dup_fd)
                op[].dup_fd = Int32(-1)
            self._state[].pool.free(op[].pool_index)
            raise e

    def _add_to_epoll(
        mut self,
        op: Pointer[_EpollOp, MutUntrackedOrigin],
        events: UInt32,
    ) raises:
        """Issue the epoll_ctl(ADD) for op, dup'ing the fd on EEXIST.

        Args:
            op: Pointer to the _EpollOp to register.
            events: Epoll event flags (EPOLLIN and/or EPOLLOUT).
                    EPOLLET is added automatically.

        Raises:
            If epoll_ctl or dup fails. On dup failure op[].dup_fd is
            left at -1; on a failed second epoll_ctl it holds the
            dup'd fd for the caller to close.
        """
        var ev = epoll_event(
            events=events | UInt32(EPOLLET), data=_event_data(op)
        )
        var res = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
            self._epfd,
            Int32(EPOLL_CTL_ADD),
            op[].fd,
            Pointer(to=ev),
        )
        if res == -Scalar[DType.int64](EEXIST):
            # fd already registered -- dup and retry.
            var dup_res = syscall[__NR_dup, Scalar[DType.int64]](op[].fd)
            var dup_fd = unsafe_decode_result[DType.int32](dup_res)
            op[].dup_fd = dup_fd
            var res2 = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
                self._epfd,
                Int32(EPOLL_CTL_ADD),
                dup_fd,
                Pointer(to=ev),
            )
            _check_for_errors(res2)
        else:
            _check_for_errors(res)

    # ── Operation methods ─────────────────────────────────────────────────

    def nop(
        mut self, c: Pointer[Completion, MutUntrackedOrigin]
    ) raises:
        """Queue a no-op. Fires with result 0 during the next tick().

        Args:
            c: Pointer to the caller-owned Completion token.
        """
        self._state[].ready.append(_ReadyEntry(c, 0, UInt32(0)))

    def connect(
        mut self,
        fd: RawHandle,
        addr: Pointer[UInt8, ImmStaticOrigin],
        addr_len: UInt64,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a connect. Issues a non-blocking connect(2) first.

        io_uring connects asynchronously whatever the socket's blocking
        mode, so this driver does too: if the socket is blocking,
        O_NONBLOCK is set for the duration of connect(2) and the
        original flags are restored right after (an in-progress
        handshake keeps progressing regardless). If connect returns
        EINPROGRESS, the fd is registered for EPOLLOUT and the result
        is read from SO_ERROR in tick(). An immediate result (success
        or an error such as -ECONNREFUSED) is enqueued to the ready
        queue and fires on the next tick().

        Args:
            fd: The socket file descriptor.
            addr: Pointer to the sockaddr structure.
            addr_len: Size in bytes of the sockaddr structure.
            c: Pointer to the caller-owned Completion token.

        Raises:
            If epoll registration fails.
        """
        var op = self._state[].pool.alloc()
        op[].kind = _OpKind.CONNECT
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].completion = c

        var flags = syscall[__NR_fcntl, Scalar[DType.int64]](
            fd, Int32(F_GETFL), Int32(0)
        )
        var force_nonblocking = (
            flags >= 0 and (flags & Scalar[DType.int64](O_NONBLOCK)) == 0
        )
        if force_nonblocking:
            _ = syscall[__NR_fcntl, Scalar[DType.int64]](
                fd,
                Int32(F_SETFL),
                flags.cast[DType.int32]() | Int32(O_NONBLOCK),
            )
        var res = syscall[__NR_connect, Scalar[DType.int64]](
            fd, addr, addr_len
        )
        if force_nonblocking:
            _ = syscall[__NR_fcntl, Scalar[DType.int64]](
                fd, Int32(F_SETFL), flags.cast[DType.int32]()
            )

        if res == -Scalar[DType.int64](EINPROGRESS):
            self._register_op(op, UInt32(EPOLLOUT))
        else:
            # Immediate result (success or error like -ECONNREFUSED).
            # Deliver as a completion callback, matching io_uring CQE
            # semantics.
            self._state[].pool.free(op[].pool_index)
            self._state[].ready.append(_ReadyEntry(c, Int(res), UInt32(0)))

    def timeout(
        mut self,
        ts: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a timeout. Fires with -ETIME when the deadline passes.

        Args:
            ts: Opaque pointer to a 16-byte __kernel_timespec
                (relative duration). Caller must keep it alive until
                the completion fires.
            c: Pointer to the caller-owned Completion token.
        """
        var ts_ptr = Pointer[__kernel_timespec, MutUntrackedOrigin](
            unsafe_from_address=Int(ts)
        )
        var deadline_ns = _monotonic_ns() + (
            ts_ptr[].tv_sec * 1_000_000_000 + ts_ptr[].tv_nsec
        )
        var op = self._state[].pool.alloc()
        op[].kind = _OpKind.TIMEOUT
        op[].fd = Int32(-1)
        op[].dup_fd = Int32(-1)
        op[].completion = c
        op[].deadline_ns = deadline_ns
        self._state[].timers.push(
            _TimerEntry(
                deadline_ns=deadline_ns, pool_index=op[].pool_index
            )
        )

    def cancel(
        mut self,
        target: Pointer[Completion, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Finds the target by Completion pointer comparison among the
        pending ops. If found, the target receives -ECANCELED and the
        cancel op succeeds with result 0. If the target is not pending
        (already completed, already cancelled, or never submitted) the
        cancel op receives -ENOENT, matching io_uring. Both fire
        during the next tick().

        Args:
            target: Pointer to the Completion of the op to cancel.
            c: Pointer to the Completion for the cancel itself.
        """
        for i in range(self._state[].pool.capacity()):
            var op = self._state[].pool.slot_ptr(i)
            if not op[].active:
                continue
            if Int(op[].completion) != Int(target):
                continue

            # Found the pending target op.
            if op[].kind is _OpKind.TIMEOUT:
                _ = self._state[].timers.remove_by_pool_index(i)
            else:
                var tracked_fd = op[].fd
                if op[].dup_fd != Int32(-1):
                    tracked_fd = op[].dup_fd
                self._epoll_remove(tracked_fd)
                if op[].dup_fd != Int32(-1):
                    close_unchecked(unsafe_fd=op[].dup_fd)

            self._state[].pool.free(i)
            self._state[].ready.append(
                _ReadyEntry(target, -Int(ECANCELED), UInt32(0))
            )
            self._state[].ready.append(_ReadyEntry(c, 0, UInt32(0)))
            return

        # Target not pending: nothing to cancel.
        self._state[].ready.append(
            _ReadyEntry(c, -Int(ENOENT), UInt32(0))
        )

    def accept(
        mut self,
        fd: RawHandle,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an accept on listening socket fd.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        var op = self._state[].pool.alloc()
        op[].kind = _OpKind.ACCEPT
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].completion = c
        self._register_op(op, UInt32(EPOLLIN))

    def recv(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a recv from socket fd into buf.

        Args:
            fd: The socket file descriptor.
            buf: Buffer to receive into. Must remain valid until
                 completion fires.
            len: Maximum bytes to receive.
            c: Pointer to the caller-owned Completion token.
        """
        var op = self._state[].pool.alloc()
        op[].kind = _OpKind.RECV
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].buf = UInt64(Int(buf))
        op[].len = len
        op[].completion = c
        self._register_op(op, UInt32(EPOLLIN))

    def send(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a send on socket fd from buf.

        Args:
            fd: The socket file descriptor.
            buf: Data to send. Must remain valid until completion fires.
            len: Number of bytes to send.
            c: Pointer to the caller-owned Completion token.
        """
        var op = self._state[].pool.alloc()
        op[].kind = _OpKind.SEND
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].buf = UInt64(Int(buf))
        op[].len = len
        op[].completion = c
        self._register_op(op, UInt32(EPOLLOUT))

    def recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a recvmsg on socket fd.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to msghdr. Must remain valid until
                 completion fires.
            c: Pointer to the caller-owned Completion token.
        """
        var op = self._state[].pool.alloc()
        op[].kind = _OpKind.RECVMSG
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].msg = UInt64(Int(msg))
        op[].completion = c
        self._register_op(op, UInt32(EPOLLIN))

    def sendmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a sendmsg on socket fd.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to msghdr. Must remain valid until
                 completion fires.
            c: Pointer to the caller-owned Completion token.
        """
        var op = self._state[].pool.alloc()
        op[].kind = _OpKind.SENDMSG
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].msg = UInt64(Int(msg))
        op[].completion = c
        self._register_op(op, UInt32(EPOLLOUT))

