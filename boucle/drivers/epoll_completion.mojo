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

Every fd-bound operation is registered through a private
close-on-exec dup (`fcntl(F_DUPFD_CLOEXEC)`) of the caller's descriptor
that the driver owns for the life of the operation; the caller's
number is never handed to epoll_ctl. See `EpollCompletionDriver` for
why.
"""

from std.collections import Optional
from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.socle.linux.raw import (
    syscall,
    epoll_event,
    __NR_epoll_ctl,
    __NR_close,
    __NR_fcntl,
    __NR_recvfrom,
    __NR_sendto,
    __NR_accept4,
    __NR_recvmsg,
    __NR_sendmsg,
    __NR_connect,
    __NR_getsockopt,
    __NR_pread64,
    __NR_pwrite64,
    __NR_fsync as __NR_fsync_,
    __NR_fdatasync,
    __kernel_timespec,
    EPOLLIN,
    EPOLLOUT,
    EPOLLET,
    EPOLLERR,
    EPOLLHUP,
    EPOLLRDHUP,
    EPOLL_CTL_ADD,
    EPOLL_CTL_DEL,
    EAGAIN,
    ECONNRESET,
    EEXIST,
    EINPROGRESS,
    EINTR,
    EINVAL,
    EIO,
    ECANCELED,
    ENOBUFS,
    ENOENT,
    ETIME,
    F_DUPFD_CLOEXEC,
    F_GETFL,
    F_SETFL,
    IORING_CQE_BUFFER_SHIFT,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    MSG_DONTWAIT,
    MSG_NOSIGNAL,
    MSG_TRUNC,
    O_CLOEXEC,
    O_NONBLOCK,
    SOL_SOCKET,
    SO_ERROR,
    iovec,
    msghdr,
)
from boucle.socle.linux.epoll.syscalls import epoll_create, epoll_wait
from boucle.net.message import DELIVERY_HEADER_LEN, write_delivery_header
from boucle.socle.linux.fd import close_unchecked
from boucle.socle.linux.errno import _check_for_errors
from boucle.socle.ptr import null_ptr
from boucle.proactor.completion import Completion
from boucle.handle import RawHandle
from boucle.error import IOError
from boucle.drivers.driver import IoDriver
from boucle.drivers.backend import Backend
from boucle.drivers.feature import DriverFeature
from boucle.pool.pool import WorkerPool
from boucle.pool._queue import WorkItem, _CompletedWork


# ── Constants ──────────────────────────────────────────────────────────────────

comptime _CLOCK_MONOTONIC = Int32(1)

# Slots the op pool starts with. It doubles on demand from there.
comptime _INITIAL_POOL_CAPACITY = 64

# Hard ceiling on pool slots: the slot index travels in the low 32 bits
# of epoll_event.data, so no more than 2^32 slots can be addressed.
comptime _MAX_POOL_CAPACITY = 1 << 32

# Most datagrams one multishot recvmsg op delivers per tick(). A consumer
# that returns buffers from its callback would otherwise let a flooding
# peer keep the drain loop inside one tick for as long as it likes,
# starving timers and every other descriptor. The value is io_uring's
# own MULTISHOT_MAX_RETRY.
comptime _MULTISHOT_MAX_PER_TICK = 32


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
    *,
    wait: Bool,
    has_deadline: Bool,
    remaining_ns: Int64,
    timeout_ms: Int = -1,
) -> Int32:
    """Compute the epoll_wait timeout for one tick().

    Rules:
        - not wait: 0, whether or not a timer is armed -- the caller has
          work to process, so never block.
        - wait, no timer armed, no bound: -1, block until an fd is ready.
        - wait, no timer armed, bound given: the bound, clamped to
          Int32.MAX.
        - wait, timer armed: milliseconds until the earliest deadline,
          in [1, Int32.MAX]. A deadline already reached gives 0. A
          positive remainder is rounded UP to whole milliseconds (so a
          sub-millisecond remainder gives 1 and epoll never wakes
          before the deadline, which would busy-spin), and anything
          beyond Int32.MAX milliseconds (~24.8 days) clamps to
          Int32.MAX; a plain Int32 cast would wrap negative, which
          epoll_wait reads as "block forever". A bound smaller than
          that remainder wins.

    Args:
        wait: Whether this tick may block at all.
        has_deadline: Whether at least one timer is armed.
        remaining_ns: Nanoseconds until the earliest deadline; only
                      read when has_deadline is True.
        timeout_ms: The caller's bound in milliseconds; -1 for none.

    Returns:
        The timeout to pass to epoll_wait: -1, 0 or a positive count
        of milliseconds no greater than Int32.MAX.
    """
    if not wait:
        return 0
    var bound = Int32(-1)
    if timeout_ms >= 0:
        bound = Int32.MAX if timeout_ms >= Int(Int32.MAX) else Int32(
            timeout_ms
        )
    if not has_deadline:
        return bound
    if remaining_ns <= 0:
        return 0
    comptime NS_PER_MS = Int64(1_000_000)
    var longest_ns = Int32.MAX.cast[DType.int64]() * NS_PER_MS
    var until_deadline = Int32.MAX
    if remaining_ns < longest_ns:
        var whole_ms_rounded_up = (remaining_ns + NS_PER_MS - 1) // NS_PER_MS
        until_deadline = whole_ms_rounded_up.cast[DType.int32]()
    if bound >= 0 and bound < until_deadline:
        return bound
    return until_deadline


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
    comptime MULTISHOT_RECVMSG = Self(9)

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

    `group_id` is only meaningful for a MULTISHOT_RECVMSG op: the
    provided-buffer group its deliveries draw from. Such an op is the
    one kind whose slot stays active while its completions fire.
    """

    var kind: _OpKind
    var fd: Int32
    var dup_fd: Int32
    var buf: UInt64
    var len: UInt32
    var addr: UInt64
    var addr_len: UInt64
    var msg: UInt64
    var flags: UInt32
    var completion: Pointer[Completion, MutUntrackedOrigin]
    var deadline_ns: Int64
    var pool_index: Int
    var generation: UInt32
    var active: Bool
    var group_id: UInt16

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
        self.flags = UInt32(0)
        self.completion = null_ptr[Completion, MutUntrackedOrigin]()
        self.deadline_ns = Int64(-1)
        self.pool_index = pool_index
        self.generation = UInt32(0)
        self.active = False
        self.group_id = UInt16(0)


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
struct _BufGroup(Copyable, Movable):
    """Userspace provided-buffer group backing the multishot emulation.

    io_uring keeps provided buffers in a kernel ring; epoll has no such
    thing, so the driver keeps the free ids itself and picks one per
    datagram in `_deliver_multishot_recvmsg`.
    """

    var id: UInt16
    var base: UInt64
    var size: UInt32
    var count: UInt32
    var free: List[UInt16]


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
    and free the slot BEFORE firing the callback, cancel scans without
    allocating, and each operation method fills its freshly allocated
    slot and registers it without allocating again. The one op that
    stays registered while its callback runs, the multishot recvmsg
    emulation, re-derives its slot pointer by index and re-checks the
    generation after every callback. Everything that outlives a call
    refers to slots by index (timer heap, epoll data), never by address.
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
    var groups: List[_BufGroup]
    var worker_pool: Optional[WorkerPool]

    def __init__(out self, *, capacity: Int):
        """Create the pool, an empty timer heap, an empty ready queue and no groups.

        The worker pool for blocking-op offload starts absent; see
        `EpollCompletionDriver._ensure_pool`.

        Args:
            capacity: Number of op slots in the pool.
        """
        self.pool = _OpPool(capacity=capacity)
        self.timers = _TimerHeap()
        self.ready = List[_ReadyEntry]()
        self.groups = List[_BufGroup]()
        self.worker_pool = None

    def __init__(out self, *, deinit move: Self):
        self.pool = move.pool^
        self.timers = move.timers^
        self.ready = move.ready^
        self.groups = move.groups^
        self.worker_pool = move.worker_pool^


# ── EpollCompletionDriver ────────────────────────────────────────────────────


# ── File I/O blocking workers ───────────────────────────────────────────────
#
# Thin functions executed on the worker pool for file I/O. Each packs
# its arguments into a heap-allocated context struct, runs the blocking
# syscall (retrying EINTR), frees the context, and returns the result
# as an Int32 (bytes transferred or negated errno).


@fieldwise_init
struct _PreadCtx:
    """Context for a blocking pread64 on a worker thread."""

    var fd: RawHandle
    var buf: Pointer[UInt8, MutUntrackedOrigin]
    var len: UInt32
    var offset: UInt64


@fieldwise_init
struct _PwriteCtx:
    """Context for a blocking pwrite64 on a worker thread."""

    var fd: RawHandle
    var buf: Pointer[UInt8, MutUntrackedOrigin]
    var len: UInt32
    var offset: UInt64


@fieldwise_init
struct _FsyncCtx:
    """Context for a blocking fsync/fdatasync on a worker thread."""

    var fd: RawHandle
    var datasync: Bool


def _blocking_pread(
    ctx_raw: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Execute pread64 on a worker thread. Retries EINTR."""
    var ctx = ctx_raw.unsafe_bitcast[_PreadCtx]()
    while True:
        var res = syscall[__NR_pread64, Scalar[DType.int64]](
            ctx[].fd,
            ctx[].buf,
            Int(ctx[].len),
            Int64(ctx[].offset),
        )
        if res >= 0:
            ctx.unsafe_deinit_pointee()
            ctx.unsafe_free()
            return Int32(res)
        if Int(-res) == EINTR:
            continue
        ctx.unsafe_deinit_pointee()
        ctx.unsafe_free()
        return Int32(res)


def _blocking_pwrite(
    ctx_raw: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Execute pwrite64 on a worker thread. Retries EINTR."""
    var ctx = ctx_raw.unsafe_bitcast[_PwriteCtx]()
    while True:
        var res = syscall[__NR_pwrite64, Scalar[DType.int64]](
            ctx[].fd,
            ctx[].buf,
            Int(ctx[].len),
            Int64(ctx[].offset),
        )
        if res >= 0:
            ctx.unsafe_deinit_pointee()
            ctx.unsafe_free()
            return Int32(res)
        if Int(-res) == EINTR:
            continue
        ctx.unsafe_deinit_pointee()
        ctx.unsafe_free()
        return Int32(res)


def _blocking_fsync(
    ctx_raw: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """Execute fsync or fdatasync on a worker thread. Retries EINTR."""
    var ctx = ctx_raw.unsafe_bitcast[_FsyncCtx]()
    var datasync = ctx[].datasync
    while True:
        var res: Scalar[DType.int64]
        if datasync:
            res = syscall[__NR_fdatasync, Scalar[DType.int64]](ctx[].fd)
        else:
            res = syscall[__NR_fsync_, Scalar[DType.int64]](ctx[].fd)
        if res == 0:
            ctx.unsafe_deinit_pointee()
            ctx.unsafe_free()
            return Int32(0)
        if Int(-res) == EINTR:
            continue
        ctx.unsafe_deinit_pointee()
        ctx.unsafe_free()
        return Int32(res)


struct EpollCompletionDriver(IoDriver):
    """IoDriver that emulates completion semantics over Linux epoll.

    Each operation method allocates an _EpollOp from a slab pool,
    stores the operation kind, buffer pointers, and Completion pointer.
    The slot index and generation go into epoll_event.data. On tick(),
    epoll_wait() fires, the op is recovered and validated, the
    non-blocking I/O is performed, and the Completion callback is
    invoked.

    The driver owns every epoll registration outright: each fd-bound
    op registers a private `dup()` of the caller's descriptor, performs
    its I/O on that dup and, on completion or cancel, removes and
    closes only that dup. The caller's number is never given to
    epoll_ctl. Two reasons. First, correctness: a caller may close its
    socket while an op is still armed (the kernel then drops the
    registration silently) and a new socket may be handed the same
    number; an EPOLL_CTL_DEL on the remembered number would then strip
    a registration that belongs to a different, live op, whose
    completion would never fire. A dup refers to the same open file
    description, so I/O through it is equivalent, but its number is
    the driver's alone until the driver closes it. Second, uniformity:
    two ops on one socket are simply two dups with two epoll entries,
    so no EEXIST special case exists. The cost is one extra descriptor
    per in-flight fd-bound operation, which counts against the
    process's RLIMIT_NOFILE alongside the caller's own sockets; an
    application that keeps many operations armed at once should size
    that limit accordingly. io_uring has no such per-op descriptor.
    The dup also keeps the socket's open file alive: a caller that
    closes its descriptor with an operation armed releases the file
    only when the next `tick()` retires the operation, so a bind to
    the same port before that tick gets EADDRINUSE.

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
        # Destroy the boxed state (pool, timers, ready queue, buffer
        # group table) and free it. Each group's free list is a List
        # field, so this also frees the group table itself; the
        # buffers a group points at are caller-owned and untouched.
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
        """
        return True

    def tick(mut self, wait: Bool, timeout_ms: Int = -1) raises -> Int:
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

        An epoll event whose data is the UInt64.MAX sentinel is the
        worker pool's wakeup fd, not an op slot; it is recognised
        before the slot index is unpacked and dispatched by draining
        the pool's finished results (see `_ensure_pool`,
        `_dispatch_pool_completions`).

        Args:
            wait: If True, block until at least one event or timer.
                  If False, return immediately after dispatching any
                  already-available events.
            timeout_ms: Upper bound on the wait in milliseconds; -1 for
                        none, 0 to poll. Folded into the epoll_wait
                        timeout together with the earliest timer.

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
        var epoll_timeout = _epoll_wait_timeout_ms(
            wait=effective_wait,
            has_deadline=has_deadline,
            remaining_ns=remaining_ns,
            timeout_ms=timeout_ms,
        )

        # 3. epoll_wait.
        var n = epoll_wait(
            self._epfd,
            self._events,
            max_events=self._max_events,
            timeout=epoll_timeout,
        )

        # 4. Dispatch epoll events, skipping stale ones.
        for i in range(Int(n)):
            var data = self._events[unsafe_offset=i].data()
            if data == UInt64.MAX:
                # The worker pool's wakeup fd, not an op slot -- checked
                # first so the sentinel is never read as a slot index.
                dispatched += self._dispatch_pool_completions()
                continue
            var index = Int(data & 0xFFFF_FFFF)
            var generation = UInt32(data >> 32)
            var op = self._state[].pool.slot_ptr(index)
            if not op[].active or op[].generation != generation:
                # The op behind this event was cancelled (or completed
                # and its slot re-used) by a callback earlier in this
                # batch; its completion has already been accounted for.
                continue
            dispatched += self._dispatch_op(
                op, self._events[unsafe_offset=i].events()
            )

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

        Used when an op completes or is cancelled. The fd is always the
        op's private dup, so nothing but this driver could have removed
        it; an error here would be a driver bug, not a caller's close.

        Args:
            fd: The op's dup to remove.
        """
        var dummy_ev = epoll_event()
        _ = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
            self._epfd,
            Int32(EPOLL_CTL_DEL),
            fd,
            Pointer(to=dummy_ev),
        )

    def _dispatch_op(
        mut self, op: Pointer[_EpollOp, MutUntrackedOrigin], events: UInt32
    ) -> Int:
        """Perform non-blocking I/O for the given op and fire its callback.

        Called from tick() when epoll_wait returns a live event for this
        _EpollOp. The actual I/O syscall happens here (not during
        operation methods), on the op's private dup. If the syscall
        reports EAGAIN (spurious wake-up, or another op on the same
        socket consumed the readiness), the op stays registered and
        nothing fires -- unless the wake carried a hang-up bit or the
        socket holds a pending error, in which case the socket will
        never yield anything and the op ends with that errno (see
        `_on_would_block`).

        The slot is detached from epoll, released to the pool and its
        dup closed BEFORE the callback fires, so a callback that
        cancels this same completion sees "not found" and a callback
        that submits a new op may legitimately re-use the slot. The one
        exception is a MULTISHOT_RECVMSG op, which stays registered and
        keeps its slot while each delivery fires; only its terminal
        completion detaches first. See `_deliver_multishot_recvmsg`.

        Args:
            op: Pointer to the live _EpollOp recovered from epoll_event.data.
            events: The event mask epoll reported for the op's dup.

        Returns:
            The number of completions fired: 1 for a one-shot op, 0 if
            EAGAIN (op stays pending), any count for a multishot op.
        """
        var kind = op[].kind
        var result = Int(0)

        if kind is _OpKind.MULTISHOT_RECVMSG:
            return self._deliver_multishot_recvmsg(op, events)

        if kind is _OpKind.RECV:
            var res = syscall[__NR_recvfrom, Scalar[DType.int64]](
                op[].dup_fd,
                Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].buf)
                ),
                UInt(op[].len),
                UInt(0),
                UInt(0),
                UInt(0),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return self._on_would_block(op, events)
            result = Int(res)

        elif kind is _OpKind.SEND:
            var res = syscall[__NR_sendto, Scalar[DType.int64]](
                op[].dup_fd,
                Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].buf)
                ),
                UInt(op[].len),
                UInt(MSG_NOSIGNAL),
                UInt(0),
                UInt(0),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return self._on_would_block(op, events)
            result = Int(res)

        elif kind is _OpKind.CONNECT:
            var optval = Int32(0)
            var optlen = Int32(4)
            var gso_res = syscall[__NR_getsockopt, Scalar[DType.int64]](
                op[].dup_fd,
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
                op[].dup_fd,
                UInt(0),
                UInt(0),
                Int32(O_CLOEXEC | O_NONBLOCK),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                # Another accept on (a dup of) this listener took the
                # connection; stay armed for the next one.
                return self._on_would_block(op, events)
            result = Int(res)

        elif kind is _OpKind.RECVMSG:
            var res = syscall[__NR_recvmsg, Scalar[DType.int64]](
                op[].dup_fd,
                Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].msg)
                ),
                Int32(UInt32(MSG_DONTWAIT) | op[].flags),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return self._on_would_block(op, events)
            result = Int(res)

        elif kind is _OpKind.SENDMSG:
            var res = syscall[__NR_sendmsg, Scalar[DType.int64]](
                op[].dup_fd,
                Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].msg)
                ),
                Int32(MSG_NOSIGNAL),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return self._on_would_block(op, events)
            result = Int(res)

        else:
            debug_assert(False, "unexpected op kind in _dispatch_op")

        # Copy what the callback needs, then release everything before
        # firing. Remove the dup from epoll first: a stale registration
        # would otherwise wake on the next data with a dead slot index.
        var completion = op[].completion
        self._detach_op(op)
        completion[].fire(result, UInt32(0))
        return 1

    def _pending_error(self, dup_fd: Int32) -> Int:
        """Read and clear the socket's pending error (`SO_ERROR`).

        `getsockopt(SO_ERROR)` consumes the error on the open file, which
        every dup of the socket shares. It is therefore reported once, to
        the first op dispatched for that wake; a second op on the same
        socket sees a clean 0 and decides from the event bits alone.

        Linux receive and send syscalls consume `sk_err` themselves
        before they return EAGAIN, so a recv or send op that would
        block on a socket with a pending error has already reported
        that error through the syscall. This query is defensive on
        those paths and reachable only for `accept`, which returns
        EAGAIN without touching `sk_err`.

        Args:
            dup_fd: The op's dup, the descriptor to query.

        Returns:
            The positive pending errno, or 0 when there is none (or the
            query itself failed).
        """
        var optval = Int32(0)
        var optlen = Int32(4)
        var gso_res = syscall[__NR_getsockopt, Scalar[DType.int64]](
            dup_fd,
            Int32(SOL_SOCKET),
            Int32(SO_ERROR),
            Pointer(to=optval),
            Pointer(to=optlen),
        )
        if gso_res < 0:
            return 0
        return Int(optval)

    def _hangup_result(self, dup_fd: Int32, events: UInt32) -> Int:
        """Derive the terminal errno for a wake that carried ERR/HUP/RDHUP.

        The socket's pending error (`SO_ERROR`) wins when there is one:
        that is what an ICMP error queued by `IP_RECVERR` or a reset
        peer reports. Reading it consumes it from the shared open file
        (see `_pending_error`), so it reaches the first op dispatched.
        Without one, a hang-up bit (the socket was shut down for
        reading, or the peer closed) reads as ECONNRESET and a bare
        EPOLLERR as EIO.

        Args:
            dup_fd: The op's dup, the descriptor to query.
            events: The reported event mask, holding at least one of
                    EPOLLERR, EPOLLHUP, EPOLLRDHUP.

        Returns:
            The negated errno the terminal completion carries.
        """
        var pending = self._pending_error(dup_fd)
        if pending != 0:
            return -pending
        if (events & UInt32(EPOLLHUP | EPOLLRDHUP)) != 0:
            return -Int(ECONNRESET)
        return -Int(EIO)

    def _on_would_block(
        mut self, op: Pointer[_EpollOp, MutUntrackedOrigin], events: UInt32
    ) -> Int:
        """Decide what a one-shot op does when its syscall returned EAGAIN.

        A plain readiness wake that another op consumed (or a spurious
        one) leaves the op armed and fires nothing. A wake carrying
        EPOLLHUP or EPOLLRDHUP, or one whose socket holds a pending
        error, will never be followed by data: the socket was shut down,
        the peer hung up or an error is queued. Such an op ends here
        with the pending error, else ECONNRESET, detached before the
        callback fires like every other terminal.

        A bare EPOLLERR with a clean `SO_ERROR` is not terminal. An
        `IP_RECVERR` socket keeps EPOLLERR asserted for as long as its
        error queue holds a record, even after the pending error was
        consumed by a socket call, so the very first wake after arming
        carries it; a datagram would still wake and complete the op.
        The op is edge-triggered, so leaving it armed cannot spin.

        Args:
            op: The live one-shot op.
            events: The event mask epoll reported.

        Returns:
            0 when the op stays armed, 1 when its terminal fired.
        """
        if (events & UInt32(EPOLLERR | EPOLLHUP | EPOLLRDHUP)) == 0:
            return 0
        var result: Int
        var pending = self._pending_error(op[].dup_fd)
        if pending != 0:
            result = -pending
        elif (events & UInt32(EPOLLHUP | EPOLLRDHUP)) != 0:
            result = -Int(ECONNRESET)
        else:
            return 0
        var completion = op[].completion
        self._detach_op(op)
        completion[].fire(result, UInt32(0))
        return 1

    def _detach_op(mut self, op: Pointer[_EpollOp, MutUntrackedOrigin]):
        """Remove the op's dup from epoll, close it and free the slot.

        The last thing done to an op before its terminal completion
        fires, so a callback that cancels this same completion sees
        "not found" and a callback that submits may reuse the slot.
        Only the op's own dup is touched: the caller's descriptor, and
        any other op's registration on the same socket, are left alone.

        Args:
            op: Pointer to the live op being retired.
        """
        var dup_fd = op[].dup_fd
        if dup_fd != Int32(-1):
            self._epoll_remove(dup_fd)
            close_unchecked(unsafe_fd=dup_fd)
            op[].dup_fd = Int32(-1)
        self._state[].pool.free(op[].pool_index)

    def _deliver_multishot_recvmsg(
        mut self, op: Pointer[_EpollOp, MutUntrackedOrigin], events: UInt32
    ) -> Int:
        """Drain the socket into provided buffers, one completion per datagram.

        For each datagram: take a free buffer id from the op's group, aim
        the msghdr's name slot, control area and single iov at the regions
        of that buffer that follow the 16-byte header (name capacity and
        control capacity come from the caller's template), call recvmsg
        with MSG_DONTWAIT | MSG_TRUNC so the return value is the full
        datagram length even when the payload region is too small, write
        the delivery header and fire with result = header + name capacity
        + control capacity + bytes copied and flags IORING_CQE_F_BUFFER |
        IORING_CQE_F_MORE | (buf_id << IORING_CQE_BUFFER_SHIFT). EAGAIN
        returns the buffer and leaves the op armed, with one exception:
        a wake that delivered nothing and carried EPOLLERR, EPOLLHUP or
        EPOLLRDHUP. The op is level-triggered, so a socket that is
        readable forever without ever yielding a datagram (shut down
        for reading, peer hung up, an error queued by `IP_RECVERR`)
        would otherwise make every epoll_wait return at once; instead
        the op ends with the errno `_hangup_result` derives (the
        pending `SO_ERROR`, else ECONNRESET for a hang-up, else EIO),
        flags 0. An empty free list,
        or a group id no longer registered (the group was unregistered
        under a live op), is the terminal -ENOBUFS (flags 0); a recvmsg
        error is terminal with that errno; a template whose regions do
        not fit the buffer, or whose name or control capacity is so
        large that the conversion to Int turns negative, is the terminal
        -EINVAL. Every terminal detaches the op before firing.

        At most `_MULTISHOT_MAX_PER_TICK` datagrams are delivered per
        call; past that the loop stops with the op still armed and data
        possibly still queued. The op's registration is level-triggered
        (see `multishot_recvmsg`), so the next epoll_wait reports the
        socket again at once and the remainder is drained on the next
        tick, after timers and every other descriptor had their turn.

        The caller's template is only read: the driver builds its own
        msghdr and iovec per datagram, so the template's pointers and
        lengths are never overwritten.

        The op stays registered across deliveries, so the slot pointer is
        re-derived from the index and the generation re-checked after
        every callback (the callback may have cancelled the op or grown
        the pool).

        Args:
            op: Pointer to the live multishot op.
            events: The event mask epoll reported for the op's dup.

        Returns:
            The number of completions fired.
        """
        var index = op[].pool_index
        var generation = op[].generation
        var fired = 0
        while fired < _MULTISHOT_MAX_PER_TICK:
            var live = self._state[].pool.slot_ptr(index)
            if not live[].active or live[].generation != generation:
                return fired
            var completion = live[].completion
            var gi = self._find_group(live[].group_id)
            if gi < 0 or len(self._state[].groups[gi].free) == 0:
                self._detach_op(live)
                completion[].fire(-Int(ENOBUFS), UInt32(0))
                return fired + 1

            var size = Int(self._state[].groups[gi].size)
            var bid = self._state[].groups[gi].free.pop()
            var base = (
                self._state[].groups[gi].base + UInt64(bid) * UInt64(size)
            )
            var tmpl = Pointer[msghdr, MutUntrackedOrigin](
                unsafe_from_address=Int(live[].msg)
            )
            var name_cap = Int(tmpl[].msg_namelen)
            var ctrl_cap = Int(tmpl[].msg_controllen)
            var payload_off = DELIVERY_HEADER_LEN + name_cap + ctrl_cap
            if name_cap < 0 or ctrl_cap < 0 or payload_off > size:
                self._state[].groups[gi].free.append(bid)
                self._detach_op(live)
                completion[].fire(-Int(EINVAL), UInt32(0))
                return fired + 1

            var iov = iovec()
            iov.iov_base = base + UInt64(payload_off)
            iov.iov_len = UInt64(size - payload_off)
            var hdr = msghdr()
            if name_cap > 0:
                hdr.msg_name = base + UInt64(DELIVERY_HEADER_LEN)
                hdr.msg_namelen = UInt32(name_cap)
            hdr.msg_iov = UInt64(Int(Pointer(to=iov)))
            hdr.msg_iovlen = UInt64(1)
            if ctrl_cap > 0:
                hdr.msg_control = base + UInt64(DELIVERY_HEADER_LEN + name_cap)
                hdr.msg_controllen = UInt64(ctrl_cap)

            var res = syscall[__NR_recvmsg, Scalar[DType.int64]](
                live[].dup_fd,
                Pointer(to=hdr),
                Int32(MSG_DONTWAIT | MSG_TRUNC),
            )
            # The iovec is referenced by address from `hdr`; keep it
            # alive past the syscall so ASAP destruction cannot reuse
            # its stack slot before the kernel reads it.
            _ = iov
            if res == -Scalar[DType.int64](EAGAIN):
                self._state[].groups[gi].free.append(bid)
                if fired > 0 or (
                    events & UInt32(EPOLLERR | EPOLLHUP | EPOLLRDHUP)
                ) == 0:
                    return fired
                var terminal = self._hangup_result(live[].dup_fd, events)
                self._detach_op(live)
                completion[].fire(terminal, UInt32(0))
                return 1
            if res < 0:
                self._state[].groups[gi].free.append(bid)
                self._detach_op(live)
                completion[].fire(Int(res), UInt32(0))
                return fired + 1

            var payload_len = Int(res)
            var copied = min(payload_len, size - payload_off)
            write_delivery_header(
                Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(base)
                ),
                namelen=hdr.msg_namelen,
                controllen=UInt32(Int(hdr.msg_controllen)),
                payloadlen=UInt32(payload_len),
                flags=UInt32(Int(hdr.msg_flags)),
            )
            var flags = UInt32(IORING_CQE_F_BUFFER | IORING_CQE_F_MORE) | (
                UInt32(bid) << UInt32(IORING_CQE_BUFFER_SHIFT)
            )
            completion[].fire(payload_off + copied, flags)
            fired += 1
        return fired

    def _register_op(
        mut self,
        op: Pointer[_EpollOp, MutUntrackedOrigin],
        events: UInt32,
        *,
        edge_triggered: Bool = True,
    ) raises:
        """Take a private dup of the op's fd and register it with epoll.

        The dup is made with `fcntl(F_DUPFD_CLOEXEC)`, so like every
        other descriptor the library creates it does not leak across an
        exec. It is stored in op[].dup_fd; every later syscall for this
        op runs on it and `_detach_op` closes it. Registering the dup
        rather than the caller's number is what keeps a caller's close,
        and the kernel's reuse of that number, from ever touching this
        driver's interest list (see the struct docstring). Because each
        op has its own dup, a second op on the same socket never sees
        EEXIST.

        If the dup fails (e.g. EMFILE) there is nothing to close and the
        slot is returned to the pool; if epoll_ctl fails (e.g. EPERM for
        a file that cannot be polled) the dup is closed and the slot
        returned. Either way the error propagates from a driver left
        exactly as it was.

        Every EPOLLIN registration also asks for EPOLLRDHUP, so a
        socket shut down for reading (or whose peer half-closed) is
        reported with that bit and the op can end instead of waiting
        for data that will never come; EPOLLERR and EPOLLHUP are always
        reported. A one-shot op ends on a hang-up bit or a pending
        socket error but not on a bare EPOLLERR; the level-triggered
        multishot op ends on any of them. See `_on_would_block` and
        `_deliver_multishot_recvmsg`.

        Args:
            op: Pointer to the freshly allocated _EpollOp to register.
            events: Epoll event flags (EPOLLIN and/or EPOLLOUT).
            edge_triggered: Add EPOLLET (the default, right for every
                            one-shot op, which consumes the readiness
                            it is woken for). False registers
                            level-triggered, for an op that may leave
                            data behind on purpose.

        Raises:
            If the dup or epoll_ctl fails.
        """
        var dup_res = syscall[__NR_fcntl, Scalar[DType.int64]](
            op[].fd, Int32(F_DUPFD_CLOEXEC), Int32(0)
        )
        if dup_res < 0:
            self._state[].pool.free(op[].pool_index)
            _check_for_errors(dup_res)
        op[].dup_fd = dup_res.cast[DType.int32]()
        var ev_flags = events
        if (events & UInt32(EPOLLIN)) != 0:
            ev_flags |= UInt32(EPOLLRDHUP)
        if edge_triggered:
            ev_flags |= UInt32(EPOLLET)
        var ev = epoll_event(events=ev_flags, data=_event_data(op))
        var res = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
            self._epfd,
            Int32(EPOLL_CTL_ADD),
            op[].dup_fd,
            Pointer(to=ev),
        )
        if res < 0:
            close_unchecked(unsafe_fd=op[].dup_fd)
            op[].dup_fd = Int32(-1)
            self._state[].pool.free(op[].pool_index)
            _check_for_errors(res)

    # ── Worker pool (blocking-op offload) ────────────────────────────────

    def _ensure_pool(mut self) raises:
        """Lazy-create the worker pool on first blocking-op submission.

        A no-op once the pool already exists. Registers the pool's
        wakeup eventfd with epoll under EPOLLIN | EPOLLET and the
        UInt64.MAX sentinel data value; tick() checks for that sentinel
        before ever treating an event's data as an op slot index. Unlike
        every other fd this driver hands to epoll_ctl, the wakeup fd is
        the pool's own descriptor rather than a private dup: the driver
        never issues I/O on it, and the pool -- not this driver -- owns
        its lifetime.

        Raises:
            If the pool's worker threads cannot be spawned, or epoll
            registration of its wakeup fd fails.
        """
        if self._state[].worker_pool.__bool__():
            return
        var pool = WorkerPool(thread_count=4)
        var ev = epoll_event(
            events=UInt32(EPOLLIN | EPOLLET), data=UInt64.MAX
        )
        var res = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
            self._epfd,
            Int32(EPOLL_CTL_ADD),
            pool.wakeup_fd(),
            Pointer(to=ev),
        )
        if res < 0:
            _check_for_errors(res)
        self._state[].worker_pool = pool^

    def _dispatch_pool_completions(mut self) -> Int:
        """Drain the worker pool's finished results and fire their Completions.

        Called from tick() when epoll reports the pool's wakeup fd
        readable (recognised by the UInt64.MAX sentinel event data).

        Returns:
            The number of completions fired.
        """
        var completed = self._state[].worker_pool.value().drain()
        for i in range(len(completed)):
            completed[i].completion[].fire(
                Int(completed[i].result), UInt32(0)
            )
        return len(completed)

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
        EINPROGRESS, a private dup of the fd is registered for EPOLLOUT
        and the result is read from SO_ERROR in tick(). An immediate result (success
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
        during the next tick(). A timer target is pulled from the timer
        heap; every other kind goes through `_detach_op` (epoll removal,
        dup close, slot release). A multishot recvmsg op is cancelled the
        same way: it is deregistered and receives -ECANCELED without
        IORING_CQE_F_MORE.

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
                self._state[].pool.free(i)
            else:
                self._detach_op(op)
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
        flags: UInt32 = 0,
    ) raises:
        """Queue a recvmsg on socket fd.

        The receive in `_dispatch_op` runs with MSG_DONTWAIT | `flags`:
        it never blocks inside tick() whatever the socket's blocking
        mode, and the caller's flags reach the kernel as given. With
        MSG_TRUNC on a datagram socket the completion result is the
        full datagram length even when the iov was too small (the
        copied bytes are capped at the iov, `msg_flags` carries
        MSG_TRUNC), the same contract the io_uring driver gives; on a
        stream socket MSG_TRUNC discards, so the caller must not ask
        for it there.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to msghdr. Must remain valid until
                 completion fires.
            c: Pointer to the caller-owned Completion token.
            flags: `recvmsg(2)` flags to pass through; 0 for none.
        """
        var op = self._state[].pool.alloc()
        op[].kind = _OpKind.RECVMSG
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].msg = UInt64(Int(msg))
        op[].flags = flags
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

    # ── File I/O via worker pool ────────────────────────────────────────

    def read(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        offset: UInt64,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a pread via the worker pool.

        Args:
            fd: File descriptor opened for reading.
            buf: Destination buffer.
            len: Maximum bytes to read.
            offset: File offset in bytes.
            c: Pointer to the caller-owned Completion token.
        """
        self._ensure_pool()
        var ctx = unsafe_alloc[_PreadCtx](1)
        ctx.unsafe_write(_PreadCtx(fd=fd, buf=buf, len=len, offset=offset))
        self._state[].worker_pool.value().submit(
            WorkItem(
                work_fn=_blocking_pread,
                context=Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=Int(ctx)
                ),
                completion=c,
            )
        )

    def write(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        len: UInt32,
        offset: UInt64,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a pwrite via the worker pool.

        Args:
            fd: File descriptor opened for writing.
            buf: Source buffer.
            len: Number of bytes to write.
            offset: File offset in bytes.
            c: Pointer to the caller-owned Completion token.
        """
        self._ensure_pool()
        var ctx = unsafe_alloc[_PwriteCtx](1)
        ctx.unsafe_write(_PwriteCtx(fd=fd, buf=buf, len=len, offset=offset))
        self._state[].worker_pool.value().submit(
            WorkItem(
                work_fn=_blocking_pwrite,
                context=Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=Int(ctx)
                ),
                completion=c,
            )
        )

    def fsync(
        mut self,
        fd: RawHandle,
        datasync: Bool,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an fsync or fdatasync via the worker pool.

        Args:
            fd: File descriptor.
            datasync: If True, fdatasync semantics.
            c: Pointer to the caller-owned Completion token.
        """
        self._ensure_pool()
        var ctx = unsafe_alloc[_FsyncCtx](1)
        ctx.unsafe_write(_FsyncCtx(fd=fd, datasync=datasync))
        self._state[].worker_pool.value().submit(
            WorkItem(
                work_fn=_blocking_fsync,
                context=Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=Int(ctx)
                ),
                completion=c,
            )
        )

    # ── Provided-buffer groups ───────────────────────────────────────────

    def _find_group(self, group_id: UInt16) -> Int:
        """Return the index of `group_id` in the group table, or -1.

        Args:
            group_id: The group to look up.
        """
        for i in range(len(self._state[].groups)):
            if self._state[].groups[i].id == group_id:
                return i
        return -1

    def register_buffer_group(
        mut self,
        base: Pointer[UInt8, MutUntrackedOrigin],
        size: UInt32,
        count: Int,
        group_id: UInt16,
    ) raises:
        """Record `count` contiguous buffers of `size` bytes as group `group_id`.

        Every id starts free; ids are handed out lowest first so the first
        delivery lands in buffer 0, as with a freshly populated io_uring
        ring.

        `count` must be in `1..65536`: buffer ids are `UInt16`, so 65536 is
        the largest free list the 16-bit buffer-id space can address
        without wrapping (io_uring's own ring stops at 32768, and
        `WatchLoop.buffer_pool` caps there for both backends).

        Args:
            base: Address of buffer 0. Must stay valid until the group is
                  unregistered.
            size: Bytes per buffer.
            count: Number of buffers, in `1..65536`.
            group_id: Caller-chosen group id.

        Raises:
            IOError(EEXIST) if `group_id` is already registered.
            IOError(EINVAL) if `size` is 0, or `count` is 0 or exceeds
                65536.
        """
        if size <= 0:
            raise IOError(positive_errno=EINVAL)
        if count <= 0 or count > 65536:
            raise IOError(positive_errno=EINVAL)
        if self._find_group(group_id) >= 0:
            raise IOError(positive_errno=EEXIST)
        var free = List[UInt16](capacity=count)
        var i = count - 1
        while i >= 0:
            free.append(UInt16(i))
            i -= 1
        self._state[].groups.append(
            _BufGroup(group_id, UInt64(Int(base)), size, UInt32(count), free^)
        )

    def unregister_buffer_group(mut self, group_id: UInt16) raises:
        """Forget group `group_id`.

        Buffers still leased out (not yet returned via `return_buffer`)
        are dropped along with the group's free list; whether that
        leaves a caller holding a dangling `buf_id` is the loop's
        problem, not this driver's -- the same contract io_uring gives
        for `IORING_OP_REMOVE_BUFFERS` on a group with leases in flight.

        Args:
            group_id: The group to remove.

        Raises:
            IOError(ENOENT) if the group is not registered.
        """
        var idx = self._find_group(group_id)
        if idx < 0:
            raise IOError(positive_errno=ENOENT)
        _ = self._state[].groups.pop(idx)

    def return_buffer(mut self, group_id: UInt16, buf_id: UInt16):
        """Make `buf_id` available to the next delivery of group `group_id`.

        Returning to an unknown group is a no-op: the group was
        unregistered while a lease was still out, and there is nothing
        left to return to. So is returning an id at or past the group's
        `count`, which names no buffer.

        Returning the same `buf_id` twice without an intervening take is
        not checked here: append never corrupts the free list itself
        (the id just appears twice, so it may be handed out twice),
        but it would then hand one buffer to two deliveries at once,
        corrupting data. This driver is a dumb free list; the "return
        at most once" invariant is the caller's to keep, one layer up
        where a leased buffer's lifetime is tracked.

        Args:
            group_id: The group the buffer belongs to.
            buf_id: The buffer id from the delivery's completion flags.
        """
        var idx = self._find_group(group_id)
        if idx < 0 or UInt32(buf_id) >= self._state[].groups[idx].count:
            return
        self._state[].groups[idx].free.append(buf_id)

    def multishot_recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutUntrackedOrigin],
        group_id: UInt16,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a multishot recvmsg into buffers of group `group_id`.

        `msg` is a template: only `msg_namelen` (peer address capacity)
        and `msg_controllen` (control capacity) are read; the name,
        control and payload regions live inside the selected buffer after
        the 16-byte delivery header. The template must stay valid until
        the terminal completion fires. One completion fires per datagram
        with IORING_CQE_F_BUFFER | IORING_CQE_F_MORE and the buffer id in
        the high 16 bits of the flags; the operation ends with -ENOBUFS
        when the group has no free buffer or is not registered (so
        unregistering a group a live stream selects from ends that
        stream with ENOBUFS), with -EINVAL when the template's regions
        do not fit a buffer of the group, with -ECANCELED on cancel, or
        with the recvmsg errno, all with flags 0. A wake that yields no
        datagram but reports an error or hang-up (the socket was shut
        down for reading, or `IP_RECVERR` queued an ICMP error) ends
        the op too, with the socket's pending error, else ECONNRESET
        for a hang-up, else EIO; an `IP_RECVERR` socket must have its
        error queue drained (`MSG_ERRQUEUE`) before the op is armed
        again, or the next wake ends it the same way. A zero-length
        receive fires a delivery with IORING_CQE_F_MORE and keeps the
        op armed, unlike io_uring, which ends the multishot on a
        zero-byte receive; the op is therefore intended for datagram
        sockets only.

        Unlike every one-shot op, the slot stays allocated and the op's
        dup stays in epoll while deliveries fire; it is released only by
        the terminal completion (see `_deliver_multishot_recvmsg`).
        Mixing a one-shot `recvmsg` with an armed multishot op on the
        same socket is undefined: whichever wakes first takes the
        datagram.

        Deliveries are bounded at `_MULTISHOT_MAX_PER_TICK` per tick, so
        the op is the one registration made level-triggered rather than
        edge-triggered: when a tick stops with datagrams still queued,
        the next epoll_wait reports the socket again without waiting
        for a new arrival. An edge-triggered entry would have lost that
        edge and left the remainder waiting for the peer's next send.

        Args:
            fd: The datagram socket.
            msg: Opaque pointer to the msghdr template.
            group_id: A group registered with `register_buffer_group`.
            c: Pointer to the caller-owned Completion token.

        Raises:
            If epoll registration fails.
        """
        var op = self._state[].pool.alloc()
        op[].kind = _OpKind.MULTISHOT_RECVMSG
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].msg = UInt64(Int(msg))
        op[].group_id = group_id
        op[].completion = c
        self._register_op(op, UInt32(EPOLLIN), edge_triggered=False)

