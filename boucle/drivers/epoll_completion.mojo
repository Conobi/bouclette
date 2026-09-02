"""Linux epoll-based completion driver for the IoDriver trait.

Emulates io_uring-style completion semantics over epoll: each
submit_* registers interest with epoll and stores a per-operation
wrapper (_EpollOp) whose address becomes the epoll_event data.
When epoll_wait fires, the wrapper is recovered, the blocking I/O
is performed, and the Completion callback is invoked -- all within
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
    ETIME,
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


# ── Constants ──────────────────────────────────────────────────────────────────

comptime _CLOCK_MONOTONIC = Int32(1)


# ── Helper: monotonic clock ───────────────────────────────────────────────────


@always_inline
def _monotonic_ns() -> Int64:
    """Read CLOCK_MONOTONIC via libc clock_gettime (VDSO, no kernel entry)."""
    var ts = __kernel_timespec(0, 0)
    _ = external_call["clock_gettime", Int32](
        _CLOCK_MONOTONIC,
        Pointer(to=ts).unsafe_bitcast[__kernel_timespec](),
    )
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec


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

    Holds everything _dispatch_op needs to perform the blocking
    I/O and fire the Completion callback.
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
        self.active = False


@fieldwise_init
struct _ReadyEntry(ImplicitlyCopyable, Movable):
    """Deferred completion for operations that complete without epoll."""

    var completion: Pointer[Completion, MutUntrackedOrigin]
    var result: Int32
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
    """Slab allocator for _EpollOp instances.

    Pre-allocates a fixed number of slots. alloc() pops a free slot
    and returns a stable pointer; free() returns the slot to the pool.
    """

    var _slots: Pointer[_EpollOp, MutUntrackedOrigin]
    var _free: List[Int]
    var _capacity: Int

    def __init__(out self, capacity: Int):
        """Create a pool with the given number of pre-allocated slots.

        Args:
            capacity: Number of op slots to pre-allocate.
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
        """Allocate a slot from the pool.

        Returns a pointer to the allocated _EpollOp. The caller must
        set all relevant fields before registering with epoll.

        Raises:
            If the pool is exhausted.
        """
        if len(self._free) == 0:
            raise "op pool exhausted (capacity=" + String(self._capacity) + ")"
        var idx = self._free.pop()
        self._slots[unsafe_offset=idx].active = True
        return self._slots.unsafe_offset(idx)

    def free(mut self, index: Int):
        """Return a slot to the pool.

        Args:
            index: The pool index of the slot to free.
        """
        self._slots[unsafe_offset=index].active = False
        self._free.append(index)

    def free_count(self) -> Int:
        """Return the number of available slots."""
        return len(self._free)

    def slot_ptr(self, index: Int) -> Pointer[_EpollOp, MutUntrackedOrigin]:
        """Return a pointer to the slot at the given index.

        Args:
            index: The pool index of the slot.

        Returns:
            Pointer to the _EpollOp at the given index.
        """
        return self._slots.unsafe_offset(index)


# ── EpollCompletionDriver ────────────────────────────────────────────────────


struct EpollCompletionDriver(IoDriver):
    """IoDriver that emulates completion semantics over Linux epoll.

    Each submit_* allocates an _EpollOp from a slab pool, stores the
    operation kind, buffer pointers, and Completion pointer. The op's
    address goes into epoll_event.data. On tick(), epoll_wait() fires,
    the op is recovered from data, blocking I/O is performed, and the
    Completion callback is invoked.

    Operations that complete without epoll (nop, cancel, immediate
    connect success) enqueue a _ReadyEntry. At the start of tick(),
    the ready queue is drained before calling epoll_wait(). ALL
    callbacks fire during tick() -- never during submit_*.
    """

    var _epfd: Int32
    var _events: Pointer[epoll_event, MutUntrackedOrigin]
    var _max_events: Int32
    var _pool: _OpPool
    var _timers: _TimerHeap
    var _ready: List[_ReadyEntry]

    def __init__(out self, *, max_events: Int32 = 64) raises:
        """Create an epoll completion driver.

        Args:
            max_events: Maximum events per epoll_wait call and initial
                        pool capacity (default 64).
        """
        self._epfd = epoll_create()
        self._max_events = max_events
        self._events = unsafe_alloc[epoll_event](Int(max_events))
        self._pool = _OpPool(capacity=Int(max_events))
        self._timers = _TimerHeap()
        self._ready = List[_ReadyEntry]()

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._epfd = move._epfd
        self._events = move._events
        self._max_events = move._max_events
        self._pool = move._pool^
        self._timers = move._timers^
        self._ready = move._ready^

    def __deinit__(deinit self):
        """Release all resources: dup'd fds, epoll fd, event buffer."""
        # Close dup'd fds for active ops.
        for i in range(self._pool._capacity):
            if self._pool._slots[unsafe_offset=i].active:
                if self._pool._slots[unsafe_offset=i].dup_fd != Int32(-1):
                    close_unchecked(
                        unsafe_fd=self._pool._slots[unsafe_offset=i].dup_fd
                    )
        # Close the epoll instance.
        close_unchecked(unsafe_fd=self._epfd)
        # Free the event buffer.
        self._events.unsafe_free()
        # _pool, _timers, _ready drop naturally (their destructors
        # free internal memory).

    def backend(self) -> Backend:
        """Return Backend.EPOLL."""
        return Backend.EPOLL

    def tick(mut self, wait: Bool) raises -> Int:
        """Drain ready queue, poll epoll, fire expired timers.

        All Completion callbacks fire here -- never during submit_*.

        Args:
            wait: If True, block until at least one event or timer.
                  If False, return immediately after dispatching any
                  already-available events.

        Returns:
            The number of dispatched completions.
        """
        var dispatched = 0

        # 1. Drain deferred-ready queue.
        for i in range(len(self._ready)):
            self._ready[i].completion[].fire(
                self._ready[i].result, self._ready[i].flags
            )
            dispatched += 1
        self._ready.clear()

        # 2. Compute epoll timeout from timer heap.
        # If we already dispatched from the ready queue, don't block —
        # the caller has work to process.
        var effective_wait = wait and dispatched == 0
        var now_ns = _monotonic_ns()
        var next_deadline = self._timers.peek_deadline()
        var timeout_ms: Int32
        if not effective_wait and next_deadline == Int64.MAX:
            timeout_ms = 0
        elif next_deadline == Int64.MAX:
            timeout_ms = -1
        else:
            var remaining_ns = next_deadline - now_ns
            var remaining_ms = remaining_ns // 1_000_000
            if remaining_ms <= 0:
                remaining_ms = 0
            if not effective_wait and remaining_ms > 0:
                remaining_ms = 0
            # Sub-millisecond remainder: round up to 1ms to avoid
            # busy-spinning when the deadline is < 1ms away.
            if effective_wait and remaining_ms == 0 and remaining_ns > 0:
                remaining_ms = 1
            timeout_ms = Int32(remaining_ms)

        # 3. epoll_wait.
        var n = epoll_wait(
            self._epfd,
            self._events,
            max_events=self._max_events,
            timeout=timeout_ms,
        )

        # 4. Dispatch epoll events.
        for i in range(Int(n)):
            var data = self._events[unsafe_offset=i].data()
            var op = Pointer[_EpollOp, MutUntrackedOrigin](
                unsafe_from_address=Int(data)
            )
            dispatched += self._dispatch_op(op)

        # 5. Fire expired timers.
        now_ns = _monotonic_ns()
        while self._timers.peek_deadline() <= now_ns:
            var entry = self._timers.pop()
            var op = self._pool.slot_ptr(entry.pool_index)
            op[].completion[].fire(
                Int32(-Int32(ETIME)), UInt32(0)
            )
            self._pool.free(entry.pool_index)
            dispatched += 1

        return dispatched

    def _dispatch_op(
        mut self, op: Pointer[_EpollOp, MutUntrackedOrigin]
    ) -> Int:
        """Perform blocking I/O for the given op and fire its callback.

        Called from tick() when epoll_wait returns an event whose data
        field points to this _EpollOp. The actual I/O syscall happens
        here (not during submit_*).

        Args:
            op: Pointer to the _EpollOp recovered from epoll_event.data.

        Returns:
            1 if a completion was dispatched, 0 if EAGAIN (op stays pending).
        """
        var result = Int32(0)

        if op[].kind is _OpKind.RECV:
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
            result = res.cast[DType.int32]()

        elif op[].kind is _OpKind.SEND:
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
            result = res.cast[DType.int32]()

        elif op[].kind is _OpKind.CONNECT:
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
                result = gso_res.cast[DType.int32]()
            elif optval == 0:
                result = Int32(0)
            else:
                result = -optval

        elif op[].kind is _OpKind.ACCEPT:
            var res = syscall[__NR_accept4, Scalar[DType.int64]](
                op[].fd,
                UInt(0),
                UInt(0),
                Int32(O_CLOEXEC | O_NONBLOCK),
            )
            result = res.cast[DType.int32]()

        elif op[].kind is _OpKind.RECVMSG:
            var res = syscall[__NR_recvmsg, Scalar[DType.int64]](
                op[].fd,
                Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].msg)
                ),
                Int32(0),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return 0
            result = res.cast[DType.int32]()

        elif op[].kind is _OpKind.SENDMSG:
            var res = syscall[__NR_sendmsg, Scalar[DType.int64]](
                op[].fd,
                Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=Int(op[].msg)
                ),
                Int32(MSG_NOSIGNAL),
            )
            if res == -Scalar[DType.int64](EAGAIN):
                return 0
            result = res.cast[DType.int32]()

        else:
            debug_assert(False, "unexpected op kind in _dispatch_op")

        # Remove fd from epoll before freeing the slot — otherwise the
        # stale _EpollOp pointer in epoll_event.data causes use-after-free
        # if new data arrives on the fd.
        if op[].kind is not _OpKind.TIMEOUT:
            var tracked_fd = op[].fd
            if op[].dup_fd != Int32(-1):
                tracked_fd = op[].dup_fd
            var dummy_ev = epoll_event()
            _ = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
                self._epfd,
                Int32(EPOLL_CTL_DEL),
                tracked_fd,
                Pointer(to=dummy_ev),
            )

        # Fire the callback.
        op[].completion[].fire(result, UInt32(0))

        # Close dup'd fd if applicable.
        if op[].dup_fd != Int32(-1):
            close_unchecked(unsafe_fd=op[].dup_fd)

        # Return slot to pool.
        self._pool.free(op[].pool_index)
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

        Args:
            op: Pointer to the _EpollOp to register.
            events: Epoll event flags (EPOLLIN and/or EPOLLOUT).
                    EPOLLET is added automatically.
        """
        var ev = epoll_event(
            events=events | UInt32(EPOLLET), data=UInt64(Int(op))
        )
        var tracked_fd = op[].fd
        var res = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
            self._epfd,
            Int32(EPOLL_CTL_ADD),
            tracked_fd,
            Pointer(to=ev),
        )
        if res == -Scalar[DType.int64](EEXIST):
            # fd already registered -- dup and retry.
            var dup_res = syscall[__NR_dup, Scalar[DType.int64]](op[].fd)
            tracked_fd = unsafe_decode_result[DType.int32](dup_res)
            op[].dup_fd = tracked_fd
            ev = epoll_event(
                events=events | UInt32(EPOLLET), data=UInt64(Int(op))
            )
            var res2 = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
                self._epfd,
                Int32(EPOLL_CTL_ADD),
                tracked_fd,
                Pointer(to=ev),
            )
            _check_for_errors(res2)
        elif res < 0:
            _check_for_errors(res)

    # ── Submit methods ────────────────────────────────────────────────────

    def submit_nop(
        mut self, c: Pointer[Completion, MutUntrackedOrigin]
    ) raises:
        """Queue a no-op. Fires with result 0 during the next tick().

        Args:
            c: Pointer to the caller-owned Completion token.
        """
        self._ready.append(_ReadyEntry(c, Int32(0), UInt32(0)))

    def submit_connect(
        mut self,
        fd: RawHandle,
        addr: Pointer[UInt8, ImmStaticOrigin],
        addr_len: UInt64,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a connect. Tries non-blocking connect first.

        If connect returns EINPROGRESS, registers for EPOLLOUT and
        defers to tick(). Immediate success enqueues to the ready
        queue.

        Args:
            fd: The socket file descriptor.
            addr: Pointer to the sockaddr structure.
            addr_len: Size in bytes of the sockaddr structure.
            c: Pointer to the caller-owned Completion token.
        """
        var op = self._pool.alloc()
        op[].kind = _OpKind.CONNECT
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].completion = c

        var res = syscall[__NR_connect, Scalar[DType.int64]](
            op[].fd, addr, addr_len
        )
        if res == -Scalar[DType.int64](EINPROGRESS):
            self._register_op(op, UInt32(EPOLLOUT))
        else:
            # Immediate result (success or error like -ECONNREFUSED).
            # Deliver as a completion callback, matching io_uring CQE semantics.
            self._ready.append(_ReadyEntry(c, Int32(res), UInt32(0)))
            self._pool.free(op[].pool_index)

    def submit_timeout(
        mut self,
        ts: Pointer[NoneType, ImmStaticOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue a timeout. Fires with -ETIME when the deadline passes.

        Args:
            ts: Opaque pointer to a 16-byte __kernel_timespec
                (relative duration).
            c: Pointer to the caller-owned Completion token.
        """
        var ts_ptr = Pointer[__kernel_timespec, ImmStaticOrigin](
            unsafe_from_address=Int(ts)
        )
        var deadline_ns = _monotonic_ns() + (
            ts_ptr[].tv_sec * 1_000_000_000 + ts_ptr[].tv_nsec
        )
        var op = self._pool.alloc()
        op[].kind = _OpKind.TIMEOUT
        op[].fd = Int32(-1)
        op[].dup_fd = Int32(-1)
        op[].completion = c
        op[].deadline_ns = deadline_ns
        self._timers.push(
            _TimerEntry(
                deadline_ns=deadline_ns, pool_index=op[].pool_index
            )
        )

    def submit_cancel(
        mut self,
        target: Pointer[Completion, MutUntrackedOrigin],
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Finds the target by Completion pointer comparison. If found,
        the target receives -ECANCELED and the cancel op succeeds
        with result 0. Both fire during the next tick().

        Args:
            target: Pointer to the Completion of the op to cancel.
            c: Pointer to the Completion for the cancel itself.
        """
        for i in range(self._pool._capacity):
            if not self._pool._slots[unsafe_offset=i].active:
                continue
            if Int(self._pool._slots[unsafe_offset=i].completion) != Int(
                target
            ):
                continue

            # Found the target op.
            if self._pool._slots[unsafe_offset=i].kind is _OpKind.TIMEOUT:
                # Remove from timer heap.
                _ = self._timers.remove_by_pool_index(i)
            else:
                # Remove from epoll.
                var tracked_fd = self._pool._slots[unsafe_offset=i].fd
                if (
                    self._pool._slots[unsafe_offset=i].dup_fd
                    != Int32(-1)
                ):
                    tracked_fd = self._pool._slots[
                        unsafe_offset=i
                    ].dup_fd
                var dummy_ev = epoll_event()
                _ = syscall[__NR_epoll_ctl, Scalar[DType.int64]](
                    self._epfd,
                    Int32(EPOLL_CTL_DEL),
                    tracked_fd,
                    Pointer(to=dummy_ev),
                )
                if (
                    self._pool._slots[unsafe_offset=i].dup_fd
                    != Int32(-1)
                ):
                    close_unchecked(
                        unsafe_fd=self._pool._slots[
                            unsafe_offset=i
                        ].dup_fd
                    )

            # Enqueue cancelled target and cancel success.
            self._ready.append(
                _ReadyEntry(
                    target, Int32(-Int32(ECANCELED)), UInt32(0)
                )
            )
            self._ready.append(_ReadyEntry(c, Int32(0), UInt32(0)))
            self._pool.free(i)
            return

        # Target not found -- already completed.
        self._ready.append(_ReadyEntry(c, Int32(0), UInt32(0)))

    def submit_accept(
        mut self,
        fd: RawHandle,
        c: Pointer[Completion, MutUntrackedOrigin],
    ) raises:
        """Queue an accept on listening socket fd.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        var op = self._pool.alloc()
        op[].kind = _OpKind.ACCEPT
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].completion = c
        self._register_op(op, UInt32(EPOLLIN))

    def submit_recv(
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
        var op = self._pool.alloc()
        op[].kind = _OpKind.RECV
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].buf = UInt64(Int(buf))
        op[].len = len
        op[].completion = c
        self._register_op(op, UInt32(EPOLLIN))

    def submit_send(
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
        var op = self._pool.alloc()
        op[].kind = _OpKind.SEND
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].buf = UInt64(Int(buf))
        op[].len = len
        op[].completion = c
        self._register_op(op, UInt32(EPOLLOUT))

    def submit_recvmsg(
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
        var op = self._pool.alloc()
        op[].kind = _OpKind.RECVMSG
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].msg = UInt64(Int(msg))
        op[].completion = c
        self._register_op(op, UInt32(EPOLLIN))

    def submit_sendmsg(
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
        var op = self._pool.alloc()
        op[].kind = _OpKind.SENDMSG
        op[].fd = fd
        op[].dup_fd = Int32(-1)
        op[].msg = UInt64(Int(msg))
        op[].completion = c
        self._register_op(op, UInt32(EPOLLOUT))

    def sq_space(mut self) -> Int:
        """Return the number of available op pool slots.

        Returns:
            The number of slots currently available for submission.
        """
        return self._pool.free_count()
