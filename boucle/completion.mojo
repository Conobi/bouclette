"""Completion-based I/O — submit work, get notified when done.

Best for:
  - Bulk data transfer (file serving, streaming)
  - Batching many operations (database engines, storage)
  - Workloads where cancellation is rare

The kernel performs I/O on your behalf. You hand over buffer
ownership and get it back on completion.

See `boucle.readiness` for the alternative model.
"""

from boucle.socle.linux.io_uring import IoUring
from boucle.socle.linux.io_uring.op import Nop, Read, Write, Recv, Send, Accept, Connect, RecvMsg, SendMsg, Timeout, ProvideBuffers, AsyncCancel
from boucle.socle.linux.io_uring.types import IoUringAcceptFlags, IoUringSqeFlags, IoUringBufReg, IoUringRegisterOp
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.linux.raw import (
    IORING_RECV_MULTISHOT,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    IORING_CQE_BUFFER_SHIFT,
)
from boucle.handle import RawHandle
from boucle.socle.ptr import null_ptr
from boucle.proactor.bufring import BufRing, _next_pow2, _IO_URING_BUF_SIZE
from boucle.proactor.completion import Completion, CompletionFn
from boucle.proactor.loop import EventLoop
from boucle.drivers import _CompletionDriver
from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc as _heap_alloc
from std.sys.info import size_of
from std.sys.intrinsics import _RegisterPackType


# ── Opaque CompletionLoop ─────────────────────────────────────────────────────


struct CompletionLoop(Movable):
    """Opaque completion event loop. Backend resolved at comptime.

    Wraps an EventLoop with the platform-appropriate completion driver
    (io_uring on Linux, IOCP on Windows, kqueue emulation on macOS).
    Consumers interact through portable IoDriver methods — the concrete
    backend is never visible.
    """

    var _inner: EventLoop[_CompletionDriver]

    def __init__(out self, sq_entries: UInt32 = 64) raises:
        """Construct a CompletionLoop with the given SQ capacity.

        Args:
            sq_entries: Number of submission queue entries (default 64).
        """
        self._inner = EventLoop[_CompletionDriver](
            _CompletionDriver(sq_entries=sq_entries)
        )

    def __init__(out self, *, deinit take: Self):
        """Move constructor."""
        self._inner = take._inner^

    def __del__(deinit self):
        """Destroy the event loop and its underlying driver."""
        self._inner^.__del__()

    # ── IoDriver delegation ───────────────────────────────────────────────

    def tick(mut self, wait: Bool) raises:
        """Submit pending SQEs and dispatch completed operations.

        Args:
            wait: If True, block until at least one completion arrives.
                  If False, return immediately after dispatching any
                  already-available completions.
        """
        self._inner.driver.tick(wait)

    def submit_nop(
        mut self, c: UnsafePointer[Completion, MutAnyOrigin]
    ) raises:
        """Queue a no-op operation.

        Args:
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_nop(c)

    def submit_connect(
        mut self,
        fd: RawHandle,
        addr: UnsafePointer[UInt8, StaticConstantOrigin],
        addr_len: UInt64,
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a connect on socket `fd` to the given address.

        Args:
            fd: The socket file descriptor.
            addr: Pointer to the sockaddr structure.
            addr_len: Size in bytes of the sockaddr structure.
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_connect(fd, addr, addr_len, c)

    def submit_timeout(
        mut self,
        ts: UnsafePointer[NoneType, StaticConstantOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a timeout (kernel timer).

        Args:
            ts: Opaque pointer to a platform-specific timespec.
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_timeout(ts, c)

    def submit_cancel(
        mut self,
        target: UnsafePointer[Completion, MutAnyOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Args:
            target: Pointer to the Completion of the op to cancel.
            c: Pointer to the Completion token for the cancel itself.
        """
        self._inner.driver.submit_cancel(target, c)

    def submit_accept(
        mut self,
        fd: RawHandle,
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue an accept on listening socket `fd`.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_accept(fd, c)

    def submit_recv(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[UInt8, MutAnyOrigin],
        len: UInt32,
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a recv from socket `fd` into `buf`.

        Args:
            fd: The socket file descriptor.
            buf: Buffer to receive into.
            len: Maximum bytes to receive.
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_recv(fd, buf, len, c)

    def submit_send(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[UInt8, MutAnyOrigin],
        len: UInt32,
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a send on socket `fd` from `buf`.

        Args:
            fd: The socket file descriptor.
            buf: Data to send.
            len: Number of bytes to send.
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_send(fd, buf, len, c)

    def submit_recvmsg(
        mut self,
        fd: RawHandle,
        msg: UnsafePointer[NoneType, MutAnyOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a recvmsg on socket `fd`.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to a platform-specific message header.
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_recvmsg(fd, msg, c)

    def submit_sendmsg(
        mut self,
        fd: RawHandle,
        msg: UnsafePointer[NoneType, MutAnyOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a sendmsg on socket `fd`.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to a platform-specific message header.
            c: Pointer to the caller-owned Completion token.
        """
        self._inner.driver.submit_sendmsg(fd, msg, c)

    def sq_space(mut self) -> Int:
        """Return the number of available submission queue slots.

        Returns:
            The number of SQ entries currently available for submission.
        """
        return self._inner.driver.sq_space()

    # ── EventLoop convenience methods ─────────────────────────────────────

    def run_once(mut self) raises:
        """Block until at least one completion fires, then dispatch all ready."""
        self._inner.run_once()

    def try_poll(mut self) raises:
        """Non-blocking: dispatch any ready completions, return immediately."""
        self._inner.try_poll()

    def run(mut self) raises:
        """Run until stop() is called."""
        self._inner.run()

    def stop(mut self):
        """Signal the loop to exit after the current tick."""
        self._inner.stop()


# ── Legacy types (deprecated — remove in Phase 5) ────────────────────────────


trait _LegacyCompletionHandler(Movable, ImplicitlyDestructible):
    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        ...


struct _LegacyCompletionLoop[Handler: _LegacyCompletionHandler]:
    """Event loop driven by kernel completions (io_uring on Linux).

    Submit I/O operations and poll for completions. Each completed
    operation invokes `Handler.on_complete` with the token, result,
    and flags from the kernel. When Handler also conforms to
    BatchCompletionHandler, `on_flush` is called once after draining
    all available CQEs.
    """

    var _ring: IoUring[]
    var _pending: UInt32
    var _handler: Self.Handler

    def __init__(out self, var handler: Self.Handler, sq_entries: UInt32 = 64) raises:
        self._ring = IoUring[](sq_entries=sq_entries)
        self._pending = 0
        self._handler = handler^

    @always_inline
    def _begin_submit(mut self) raises:
        """Check submission queue capacity and track the pending operation."""
        if not self._ring.sq():
            raise "submission queue full"
        self._pending += 1

    def submit_nop(mut self, token: UInt64 = 0) raises:
        """Queue a no-op. Useful for testing and drain synchronisation."""
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = Nop(sq.__next__()).user_data(token)

    def submit_read(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
        offset: UInt64 = 0,
    ) raises:
        """Queue a read from `fd` into `buf`."""
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = Read(sq.__next__(), fd, buf, len).user_data(token).offset(offset)

    def submit_write(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
        offset: UInt64 = 0,
    ) raises:
        """Queue a write from `buf` to `fd`."""
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = Write(sq.__next__(), fd, buf, len).user_data(token).offset(offset)

    def submit_recv(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
    ) raises:
        """Queue a recv from socket `fd` into `buf`."""
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = Recv(sq.__next__(), fd, buf, len).user_data(token)

    def submit_send(
        mut self,
        fd: RawHandle,
        buf: UnsafePointer[Int8, StaticConstantOrigin],
        len: UInt,
        token: UInt64,
    ) raises:
        """Queue a send on socket `fd` from `buf`."""
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = Send(sq.__next__(), fd, buf, len).user_data(token)

    def submit_accept(mut self, fd: RawHandle, token: UInt64) raises:
        """Queue an accept on listening socket `fd`."""
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = Accept(sq.__next__(), fd).user_data(token)

    def submit_accept_multishot(mut self, fd: RawHandle, token: UInt64) raises:
        """Queue a multishot accept on listening socket `fd`.

        Produces one CQE per accepted connection. Re-submit only when
        CQE flags lack IORING_CQE_F_MORE (multishot ended).
        Requires kernel >= 5.19.
        """
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = Accept(sq.__next__(), fd).ioprio(IoUringAcceptFlags.MULTISHOT.value).user_data(token)

    def submit_connect(
        mut self,
        fd: RawHandle,
        addr_unsafe_ptr: UnsafePointer[UInt8, StaticConstantOrigin],
        addr_len: UInt64,
        token: UInt64,
    ) raises:
        """Queue a connect on socket `fd` to the given address.

        The memory pointed to by `addr_unsafe_ptr` must remain valid
        until the completion fires.
        """
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        var addr_cv = UnsafePointer[c_void, StaticConstantOrigin](
            unsafe_from_address=Int(addr_unsafe_ptr)
        )
        _ = Connect(sq.__next__(), fd, addr_cv, addr_len).user_data(token)

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
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = RecvMsg(sq.__next__(), fd, msghdr_ptr).recv_flags(flags).user_data(token)

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
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = SendMsg(sq.__next__(), fd, msghdr_ptr).send_flags(flags).user_data(token)

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
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = Timeout(sq.__next__(), ts_ptr).user_data(token)

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
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = AsyncCancel(sq.__next__(), target_user_data).cancel_flags(flags).user_data(token)

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
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
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

    def reprovide_buffer(
        mut self,
        buf_ptr: UnsafePointer[UInt8, MutAnyOrigin],
        buf_size: Int,
        group_id: UInt16,
        buf_id: UInt16,
        token: UInt64 = 0,
    ) raises:
        """Re-provide a single buffer after processing its data."""
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
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
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        _ = RecvMsg(sq.__next__(), fd, msghdr_ptr)
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(token)

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
        self._begin_submit()
        var sq = self._ring.unsynced_sq()
        var null_addr = null_ptr[c_void, StaticConstantOrigin]()
        _ = Recv(sq.__next__(), fd, null_addr, UInt(0))
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(token)

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

        The ring requires a power-of-2 number of slots; `count` is
        rounded up if needed. Only `count` entries are populated,
        so `buf_base` must hold at least `count * buf_size` bytes.
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
            UInt32(count),
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
        When Handler conforms to BatchCompletionHandler, also calls
        `Handler.on_flush` once after all CQEs are drained.
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
        comptime if conforms_to(Self.Handler, _LegacyBatchCompletionHandler):
            self._handler.on_flush()

    def run(mut self) raises:
        """Run until all pending operations complete."""
        while self._pending > 0:
            self.poll(wait_nr=1)


trait _LegacyBatchCompletionHandler(_LegacyCompletionHandler):
    """Extension of _LegacyCompletionHandler with batch flush notification.

    After all available CQEs are dispatched via on_complete(), the loop
    calls on_flush() once, allowing the handler to process buffered work
    as a batch.
    """
    def on_flush(mut self):
        ...


comptime _LegacyBatchCompletionLoop = _LegacyCompletionLoop
"""_LegacyCompletionLoop with batch flush — use with a _LegacyBatchCompletionHandler.

When Handler conforms to _LegacyBatchCompletionHandler, _LegacyCompletionLoop
automatically calls on_flush() after draining CQEs. This alias exists
for API discoverability; it is identical to _LegacyCompletionLoop.
"""
