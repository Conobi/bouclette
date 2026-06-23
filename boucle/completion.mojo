"""Completion-based I/O — submit work, get notified when done.

Best for:
  - Bulk data transfer (file serving, streaming)
  - Batching many operations (database engines, storage)
  - Workloads where cancellation is rare

The kernel performs I/O on your behalf. You hand over buffer
ownership and get it back on completion.

See `boucle.readiness` for the alternative model.
"""

from boucle._sys.linux.io_uring import IoUring
from boucle._sys.linux.io_uring.op import Nop, Read, Write, Recv, Send, Accept, Connect, RecvMsg, SendMsg, Timeout, ProvideBuffers, AsyncCancel
from boucle._sys.linux.io_uring.types import IoUringAcceptFlags, IoUringSqeFlags, IoUringBufReg, IoUringRegisterOp
from boucle._sys.linux.raw.ctypes import c_void
from boucle._sys.linux.raw import (
    IORING_RECV_MULTISHOT,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    IORING_CQE_BUFFER_SHIFT,
)
from boucle.handle import RawHandle
from boucle._sys.ptr import null_ptr
from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc as _heap_alloc
from std.sys.info import size_of
from std.sys.intrinsics import _RegisterPackType


# ── Buffer ring (IORING_REGISTER_PBUF_RING) ─────────────────────────────
#
# A user-mapped ring of `io_uring_buf` entries, registered with io_uring
# under a `bgid` (buffer group id). Replaces the older
# `IORING_OP_PROVIDE_BUFFERS` SQE-per-reprovide path: returning a buffer
# is a userspace store + atomic store-release on the ring tail, no
# syscall, no kernel buffer-pool tree.
#
# Layout per kernel: ring entries are `struct io_uring_buf { addr, len,
# bid, resv }` — 16 bytes each. The first slot's last 2 bytes (offset
# 14..15) overlay the ring tail. The user writes `tail` there with a
# store-release; the kernel reads it with a load-acquire.


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


struct BufRing(Movable):
    """A registered provided-buffer ring.

    Use after `CompletionLoop.register_buf_ring`. The kernel selects
    buffers from this ring per multishot recv. Return a consumed buffer
    via `add_buffer(buf_id)` after processing the CQE — userspace only.
    """

    var ring_addr: UnsafePointer[UInt8, MutAnyOrigin]
    var ring_entries: UInt32
    var mask: UInt32
    var bgid: UInt16
    var buf_base: UnsafePointer[UInt8, MutAnyOrigin]
    var buf_size: UInt32
    var owns_ring: Bool

    def __init__(
        out self,
        ring_addr: UnsafePointer[UInt8, MutAnyOrigin],
        ring_entries: UInt32,
        bgid: UInt16,
        buf_base: UnsafePointer[UInt8, MutAnyOrigin],
        buf_size: UInt32,
    ):
        debug_assert(
            ring_entries > 0 and (ring_entries & (ring_entries - 1)) == 0,
            "ring_entries must be a power of 2",
        )
        self.ring_addr = ring_addr
        self.ring_entries = ring_entries
        self.mask = ring_entries - UInt32(1)
        self.bgid = bgid
        self.buf_base = buf_base
        self.buf_size = buf_size
        self.owns_ring = True

    def __init__(out self):
        """Empty BufRing (no allocations). Use to construct an
        H2ServerHandler-style consumer before `register_buf_ring`. The
        consumer must move-assign the real BufRing into place before
        any add_buffer / buf_base access."""
        self.ring_addr = null_ptr[UInt8, MutAnyOrigin]()
        self.ring_entries = UInt32(0)
        self.mask = UInt32(0)
        self.bgid = UInt16(0)
        self.buf_base = null_ptr[UInt8, MutAnyOrigin]()
        self.buf_size = UInt32(0)
        self.owns_ring = False

    def __init__(out self, *, deinit take: Self):
        self.ring_addr = take.ring_addr
        self.ring_entries = take.ring_entries
        self.mask = take.mask
        self.bgid = take.bgid
        self.buf_base = take.buf_base
        self.buf_size = take.buf_size
        self.owns_ring = take.owns_ring
        take.owns_ring = False

    def __del__(deinit self):
        if self.owns_ring:
            self.ring_addr.free()

    @always_inline
    def _tail_ptr(self) -> UnsafePointer[UInt16, MutAnyOrigin]:
        return UnsafePointer[UInt16, MutAnyOrigin](
            unsafe_from_address=Int(self.ring_addr) + _IO_URING_BUF_TAIL_OFFSET
        )

    @always_inline
    def _entry_ptr(self, slot: UInt32) -> UnsafePointer[UInt8, MutAnyOrigin]:
        return UnsafePointer[UInt8, MutAnyOrigin](
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
        UnsafePointer[UInt64, MutAnyOrigin](
            unsafe_from_address=Int(ent) + _BUF_ADDR_OFFSET
        )[] = addr
        # len at _BUF_LEN_OFFSET (4 bytes)
        UnsafePointer[UInt32, MutAnyOrigin](
            unsafe_from_address=Int(ent) + _BUF_LEN_OFFSET
        )[] = len
        # bid at _BUF_BID_OFFSET (2 bytes)
        UnsafePointer[UInt16, MutAnyOrigin](
            unsafe_from_address=Int(ent) + _BUF_BID_OFFSET
        )[] = bid
        # resv at _IO_URING_BUF_TAIL_OFFSET — DO NOT touch when slot == 0
        # (overlays tail). When slot != 0, leaving it as whatever the
        # previous tail value was is harmless (kernel ignores resv).

    def add_buffer(mut self, buf_id: UInt16):
        """Return a buffer (identified by `buf_id` from a recv CQE) to
        the ring so the kernel can pick it for a future arrival."""
        debug_assert(
            UInt32(buf_id) < self.ring_entries,
            "buf_id exceeds ring capacity",
        )
        var tp = self._tail_ptr()
        var current_tail = tp[]
        var slot = UInt32(current_tail) & self.mask
        var addr = UInt64(Int(self.buf_base)) + UInt64(buf_id) * UInt64(self.buf_size)
        self._write_entry(slot, addr, self.buf_size, buf_id)
        # store-release on tail. Mojo doesn't expose acq/rel intrinsics
        # on plain pointers; a normal store followed by a compiler
        # barrier is sufficient on x86-64 (TSO) for store-release
        # semantics, since stores are not reordered with each other.
        tp[] = current_tail + UInt16(1)

    def populate_initial(mut self):
        """Fill every ring slot with its own data buffer and advance tail
        to ring_entries. Call once after register_buf_ring."""
        var tp = self._tail_ptr()
        for i in range(Int(self.ring_entries)):
            var bid = UInt16(i)
            var addr = UInt64(Int(self.buf_base)) + UInt64(i) * UInt64(self.buf_size)
            self._write_entry(UInt32(i), addr, self.buf_size, bid)
        tp[] = UInt16(self.ring_entries)


def _next_pow2(n: Int) -> Int:
    var p = 1
    while p < n:
        p = p << 1
    return p


trait CompletionHandler(Movable, ImplicitlyDestructible):
    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        ...


struct CompletionLoop[Handler: CompletionHandler]:
    """Event loop driven by kernel completions (io_uring on Linux).

    Submit I/O operations and poll for completions. Each completed
    operation invokes `Handler.on_complete` with the token, result,
    and flags from the kernel.
    """

    var _ring: IoUring[]
    var _pending: UInt32
    var _handler: Self.Handler

    def __init__(out self, var handler: Self.Handler, sq_entries: UInt32 = 64) raises:
        self._ring = IoUring[](sq_entries=sq_entries)
        self._pending = 0
        self._handler = handler^

    def submit_nop(mut self, token: UInt64 = 0) raises:
        """Queue a no-op. Useful for testing and drain synchronisation."""
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (nop)"
        _ = Nop(sq.__next__()).user_data(token)
        self._pending += 1

    def submit_read(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
        offset: UInt64 = 0,
    ) raises:
        """Queue a read from `fd` into `buf`."""
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (read)"
        _ = Read(sq.__next__(), fd, buf, len).user_data(token).offset(offset)
        self._pending += 1

    def submit_write(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
        offset: UInt64 = 0,
    ) raises:
        """Queue a write from `buf` to `fd`."""
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (write)"
        _ = Write(sq.__next__(), fd, buf, len).user_data(token).offset(offset)
        self._pending += 1

    def submit_recv(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
    ) raises:
        """Queue a recv from socket `fd` into `buf`."""
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (recv)"
        _ = Recv(sq.__next__(), fd, buf, len).user_data(token)
        self._pending += 1

    def submit_send(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
    ) raises:
        """Queue a send on socket `fd` from `buf`."""
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (send)"
        _ = Send(sq.__next__(), fd, buf, len).user_data(token)
        self._pending += 1

    def submit_accept(mut self, fd: RawHandle, token: UInt64) raises:
        """Queue an accept on listening socket `fd`."""
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (accept)"
        _ = Accept(sq.__next__(), fd).user_data(token)
        self._pending += 1

    def submit_accept_multishot(mut self, fd: RawHandle, token: UInt64) raises:
        """Queue a multishot accept on listening socket `fd`.

        Produces one CQE per accepted connection. Re-submit only when
        CQE flags lack IORING_CQE_F_MORE (multishot ended).
        Requires kernel >= 5.19.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (accept_multishot)"
        _ = Accept(sq.__next__(), fd).ioprio(IoUringAcceptFlags.MULTISHOT.value).user_data(token)
        self._pending += 1

    def submit_connect(
        mut self,
        fd: RawHandle,
        addr_unsafe_ptr: UnsafePointer[Int8, StaticConstantOrigin],
        addr_len: UInt64,
        token: UInt64,
    ) raises:
        """Queue a connect on socket `fd` to the given address.

        The memory pointed to by `addr_unsafe_ptr` must remain valid
        until the completion fires.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (connect)"
        _ = Connect(sq.__next__(), fd, addr_unsafe_ptr, addr_len).user_data(
            token
        )
        self._pending += 1

    def submit_recvmsg(
        mut self,
        fd: RawHandle,
        msghdr_ptr: UnsafePointer[c_void, StaticConstantOrigin],
        token: UInt64,
        flags: UInt32 = 0,
    ) raises:
        """Queue a recvmsg on socket `fd`.

        The memory pointed to by `msghdr_ptr` (and all buffers it
        references) must remain valid until the completion fires.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (recvmsg)"
        _ = RecvMsg(sq.__next__(), fd, msghdr_ptr).recv_flags(flags).user_data(
            token
        )
        self._pending += 1

    def submit_sendmsg(
        mut self,
        fd: RawHandle,
        msghdr_ptr: UnsafePointer[c_void, StaticConstantOrigin],
        token: UInt64,
        flags: UInt32 = 0,
    ) raises:
        """Queue a sendmsg on socket `fd`.

        The memory pointed to by `msghdr_ptr` (and all buffers it
        references) must remain valid until the completion fires.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (sendmsg)"
        _ = SendMsg(sq.__next__(), fd, msghdr_ptr).send_flags(flags).user_data(
            token
        )
        self._pending += 1

    def submit_timeout(
        mut self,
        ts_ptr: UnsafePointer[c_void, StaticConstantOrigin],
        token: UInt64,
    ) raises:
        """Queue a timeout. `ts_ptr` points to a 16-byte kernel_timespec.

        CQE result is -ETIME on normal expiry, 0 if canceled.
        The memory pointed to by `ts_ptr` must remain valid until
        the completion fires.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (timeout)"
        _ = Timeout(sq.__next__(), ts_ptr).user_data(token)
        self._pending += 1

    def submit_cancel(
        mut self,
        token: UInt64,
        target_user_data: UInt64,
        flags: UInt32 = 0,
    ) raises:
        """Cancel a previously submitted op matched by `target_user_data`.

        The cancel itself produces a CQE with `user_data == token` and either
        `result == 0` (target was in flight, cancelled) or `result == -ENOENT`
        (target had already completed). When cancelled in flight, the target
        op also produces a CQE with `result == -ECANCELED`.

        `flags` accepts `IORING_ASYNC_CANCEL_*` bits (0 = match a single op
        by `target_user_data`).
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (cancel)"
        _ = AsyncCancel(sq.__next__(), target_user_data).cancel_flags(flags).user_data(token)
        self._pending += 1

    def provide_buffers(
        mut self,
        buf_base: UnsafePointer[UInt8, MutAnyOrigin],
        buf_size: Int,
        count: Int,
        group_id: UInt16,
        base_buf_id: UInt16,
        token: UInt64 = 0,
    ) raises:
        """Register count contiguous buffers with io_uring.

        Buffers are contiguous: buf_base[i * buf_size .. (i+1) * buf_size].
        Each buffer gets ID base_buf_id + i.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (provide_buffers)"
        var buf_ptr = UnsafePointer[c_void, StaticConstantOrigin](
            unsafe_from_address=Int(buf_base)
        )
        _ = ProvideBuffers(
            sq.__next__(),
            buf_ptr,
            UInt32(buf_size),
            UInt32(count),
            group_id,
            base_buf_id,
        ).user_data(token)
        self._pending += 1

    def reprovide_buffer(
        mut self,
        buf_ptr: UnsafePointer[UInt8, MutAnyOrigin],
        buf_size: Int,
        group_id: UInt16,
        buf_id: UInt16,
        token: UInt64 = 0,
    ) raises:
        """Re-provide a single buffer after processing its data."""
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (reprovide_buffer)"
        var ptr = UnsafePointer[c_void, StaticConstantOrigin](
            unsafe_from_address=Int(buf_ptr)
        )
        _ = ProvideBuffers(
            sq.__next__(),
            ptr,
            UInt32(buf_size),
            UInt32(1),
            group_id,
            buf_id,
        ).user_data(token)
        self._pending += 1

    def submit_recvmsg_multishot(
        mut self,
        fd: RawHandle,
        msghdr_ptr: UnsafePointer[c_void, StaticConstantOrigin],
        buf_group: UInt16,
        token: UInt64,
    ) raises:
        """Queue a multishot recvmsg with provided buffer selection.

        Produces one CQE per received message. The buffer ID is in
        CQE.flags >> 16 when IORING_CQE_F_BUFFER is set.
        Re-submit when CQE flags lack IORING_CQE_F_MORE.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (recvmsg_multishot)"
        _ = RecvMsg(sq.__next__(), fd, msghdr_ptr)
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(token)
        self._pending += 1

    def submit_recv_multishot(
        mut self,
        fd: RawHandle,
        buf_group: UInt16,
        token: UInt64,
    ) raises:
        """Queue a multishot recv with provided buffer selection (TCP).

        Like submit_recv but the kernel selects a buffer from `buf_group`
        per arrival and produces one CQE per chunk. Unlike recvmsg, the
        payload begins at offset 0 of the chosen buffer (no
        io_uring_recvmsg_out header). The buffer ID is in
        CQE.flags >> 16 when IORING_CQE_F_BUFFER is set; re-submit when
        CQE flags lack IORING_CQE_F_MORE.

        Buffer pointer (NULL) and length (0) are placeholders — the
        kernel ignores them when BUFFER_SELECT is set.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (recv_multishot)"
        var null_addr = null_ptr[c_void, StaticConstantOrigin]()
        _ = Recv(sq.__next__(), fd, null_addr, UInt(0))
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(token)
        self._pending += 1

    def register_buf_ring(
        mut self,
        buf_base: UnsafePointer[UInt8, MutAnyOrigin],
        buf_size: UInt32,
        count: Int,
        group_id: UInt16,
    ) raises -> BufRing:
        """Register a user-mapped provided-buffer ring (since kernel 5.19).

        Returning a consumed buffer to the ring is a userspace store on
        `BufRing.add_buffer(buf_id)` — no SQE, no syscall, no kernel
        buffer-pool tree. Recommended for hot recv paths where the
        SQE-per-reprovide cost of the older `provide_buffers` path
        dominates.

        `count` must be a power of 2; if it isn't, it is rounded up.
        Allocates the ring and pre-fills `count` entries each pointing
        at `buf_base + i * buf_size` (i = 0..count-1).
        """
        var entries = UInt32(_next_pow2(count))
        debug_assert(
            Int(entries) <= Int(UInt32.MAX) // _IO_URING_BUF_SIZE,
            "ring too large",
        )
        var ring_bytes = Int(entries) * _IO_URING_BUF_SIZE
        var ring_mem = _heap_alloc[UInt8](ring_bytes).as_unsafe_any_origin()
        for i in range(ring_bytes):
            ring_mem[i] = UInt8(0)

        var bring = BufRing(
            ring_mem,
            entries,
            group_id,
            buf_base,
            buf_size,
        )

        var reg = IoUringBufReg(
            ring_addr=UInt64(Int(ring_mem)),
            ring_entries=entries,
            bgid=group_id,
        )
        var arg = reg.as_register_arg(
            unsafe_opcode=IoUringRegisterOp.REGISTER_PBUF_RING
        )
        _ = self._ring.register(arg)

        bring.populate_initial()
        return bring^

    def unregister_buf_ring(mut self, group_id: UInt16) raises:
        """Tear down a registered buffer ring (use `BufRing.bgid`)."""
        var reg = IoUringBufReg(bgid=group_id)
        var arg = reg.as_register_arg(
            unsafe_opcode=IoUringRegisterOp.UNREGISTER_PBUF_RING
        )
        _ = self._ring.register(arg)

    def poll(mut self, *, wait_nr: UInt32 = 1) raises:
        """Submit queued SQEs and drain available completions.

        Calls `Handler.on_complete` for each completed operation.
        """
        _ = self._ring.submit_and_wait(wait_nr=wait_nr)
        var cq = self._ring.cq(wait_nr=0)
        while cq:
            var cqe = cq.__next__()
            var flags = UInt32(cqe.flags.value)
            self._handler.on_complete(cqe.user_data, cqe.res, flags)
            # Multishot ops produce multiple CQEs per submission. Only the
            # terminal CQE (flag IORING_CQE_F_MORE cleared) retires the op.
            if (flags & IORING_CQE_F_MORE) == 0:
                self._pending -= 1
        cq^.__del__()

    def run(mut self) raises:
        """Run until all pending operations complete."""
        while self._pending > 0:
            self.poll(wait_nr=1)


trait BatchCompletionHandler(CompletionHandler):
    """Extension of CompletionHandler with batch flush notification.

    After all available CQEs are dispatched via on_complete(), the loop
    calls on_flush() once, allowing the handler to process buffered work
    as a batch.
    """
    def on_flush(mut self):
        ...


struct BatchCompletionLoop[Handler: BatchCompletionHandler]:
    """Event loop that drains all available completions before flushing.

    Same submit API as CompletionLoop. The poll() method waits for at
    least 1 CQE, drains all available CQEs via on_complete(), then
    calls on_flush() once for batch processing.
    """

    var _ring: IoUring[]
    var _pending: UInt32
    var _handler: Self.Handler

    def __init__(out self, var handler: Self.Handler, sq_entries: UInt32 = 64) raises:
        self._ring = IoUring[](sq_entries=sq_entries)
        self._pending = 0
        self._handler = handler^

    def submit_nop(mut self, token: UInt64 = 0) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (nop)"
        _ = Nop(sq.__next__()).user_data(token)
        self._pending += 1

    def submit_read(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
        offset: UInt64 = 0,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (read)"
        _ = Read(sq.__next__(), fd, buf, len).user_data(token).offset(offset)
        self._pending += 1

    def submit_write(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
        offset: UInt64 = 0,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (write)"
        _ = Write(sq.__next__(), fd, buf, len).user_data(token).offset(offset)
        self._pending += 1

    def submit_recv(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (recv)"
        _ = Recv(sq.__next__(), fd, buf, len).user_data(token)
        self._pending += 1

    def submit_send(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (send)"
        _ = Send(sq.__next__(), fd, buf, len).user_data(token)
        self._pending += 1

    def submit_accept(mut self, fd: RawHandle, token: UInt64) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (accept)"
        _ = Accept(sq.__next__(), fd).user_data(token)
        self._pending += 1

    def submit_accept_multishot(mut self, fd: RawHandle, token: UInt64) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (accept_multishot)"
        _ = Accept(sq.__next__(), fd).ioprio(IoUringAcceptFlags.MULTISHOT.value).user_data(token)
        self._pending += 1

    def submit_connect(
        mut self,
        fd: RawHandle,
        addr_unsafe_ptr: UnsafePointer[Int8, StaticConstantOrigin],
        addr_len: UInt64,
        token: UInt64,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (connect)"
        _ = Connect(sq.__next__(), fd, addr_unsafe_ptr, addr_len).user_data(token)
        self._pending += 1

    def submit_recvmsg(
        mut self,
        fd: RawHandle,
        msghdr_ptr: UnsafePointer[c_void, StaticConstantOrigin],
        token: UInt64,
        flags: UInt32 = 0,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (recvmsg)"
        _ = RecvMsg(sq.__next__(), fd, msghdr_ptr).recv_flags(flags).user_data(token)
        self._pending += 1

    def submit_sendmsg(
        mut self,
        fd: RawHandle,
        msghdr_ptr: UnsafePointer[c_void, StaticConstantOrigin],
        token: UInt64,
        flags: UInt32 = 0,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (sendmsg)"
        _ = SendMsg(sq.__next__(), fd, msghdr_ptr).send_flags(flags).user_data(token)
        self._pending += 1

    def submit_timeout(
        mut self,
        ts_ptr: UnsafePointer[c_void, StaticConstantOrigin],
        token: UInt64,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (timeout)"
        _ = Timeout(sq.__next__(), ts_ptr).user_data(token)
        self._pending += 1

    def submit_cancel(
        mut self,
        token: UInt64,
        target_user_data: UInt64,
        flags: UInt32 = 0,
    ) raises:
        """Cancel a previously submitted op matched by `target_user_data`.

        See `CompletionLoop.submit_cancel` for semantics.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (cancel)"
        _ = AsyncCancel(sq.__next__(), target_user_data).cancel_flags(flags).user_data(token)
        self._pending += 1

    def provide_buffers(
        mut self,
        buf_base: UnsafePointer[UInt8, MutAnyOrigin],
        buf_size: Int,
        count: Int,
        group_id: UInt16,
        base_buf_id: UInt16,
        token: UInt64 = 0,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (provide_buffers)"
        var buf_ptr = UnsafePointer[c_void, StaticConstantOrigin](
            unsafe_from_address=Int(buf_base)
        )
        _ = ProvideBuffers(
            sq.__next__(), buf_ptr, UInt32(buf_size), UInt32(count),
            group_id, base_buf_id,
        ).user_data(token)
        self._pending += 1

    def reprovide_buffer(
        mut self,
        buf_ptr: UnsafePointer[UInt8, MutAnyOrigin],
        buf_size: Int,
        group_id: UInt16,
        buf_id: UInt16,
        token: UInt64 = 0,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (reprovide_buffer)"
        var ptr = UnsafePointer[c_void, StaticConstantOrigin](
            unsafe_from_address=Int(buf_ptr)
        )
        _ = ProvideBuffers(
            sq.__next__(), ptr, UInt32(buf_size), UInt32(1),
            group_id, buf_id,
        ).user_data(token)
        self._pending += 1

    def submit_recvmsg_multishot(
        mut self,
        fd: RawHandle,
        msghdr_ptr: UnsafePointer[c_void, StaticConstantOrigin],
        buf_group: UInt16,
        token: UInt64,
    ) raises:
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (recvmsg_multishot)"
        _ = RecvMsg(sq.__next__(), fd, msghdr_ptr)
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(token)
        self._pending += 1

    def submit_recv_multishot(
        mut self,
        fd: RawHandle,
        buf_group: UInt16,
        token: UInt64,
    ) raises:
        """Queue a multishot recv with provided buffer selection (TCP).

        Like submit_recv but the kernel selects a buffer from `buf_group`
        per arrival and produces one CQE per chunk. The payload begins at
        offset 0 of the chosen buffer (no io_uring_recvmsg_out header).
        Re-submit when CQE flags lack IORING_CQE_F_MORE.
        """
        var sq = self._ring.sq()
        if not sq:
            raise "submission queue full (recv_multishot)"
        var null_addr = null_ptr[c_void, StaticConstantOrigin]()
        _ = Recv(sq.__next__(), fd, null_addr, UInt(0))
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(token)
        self._pending += 1

    def poll(mut self, *, wait_nr: UInt32 = 1) raises:
        """Submit queued SQEs, drain all available completions, then flush.

        Calls Handler.on_complete for each completed operation,
        then Handler.on_flush once after all CQEs are drained.
        """
        _ = self._ring.submit_and_wait(wait_nr=wait_nr)
        var cq = self._ring.cq(wait_nr=0)
        while cq:
            var cqe = cq.__next__()
            var flags = UInt32(cqe.flags.value)
            self._handler.on_complete(cqe.user_data, cqe.res, flags)
            # Multishot ops produce multiple CQEs per submission. Only the
            # terminal CQE (flag IORING_CQE_F_MORE cleared) retires the op.
            if (flags & IORING_CQE_F_MORE) == 0:
                self._pending -= 1
        cq^.__del__()
        self._handler.on_flush()

    def run(mut self) raises:
        while self._pending > 0:
            self.poll(wait_nr=1)
