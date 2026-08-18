"""Linux io_uring backend for the proactor IoDriver trait.

Wraps boucle's IoUring type and implements tick() (CQE dispatch via
Completion pointer recovery) and submit methods (nop, connect,
timeout, cancel).
"""

from std.memory import Pointer

from std.memory.alloc import unsafe_alloc as _heap_alloc

from boucle.socle.linux.io_uring import IoUring
from boucle.socle.linux.io_uring.op import Nop, Connect, Accept, Recv, Send, RecvMsg, SendMsg, Timeout, AsyncCancel, ProvideBuffers
from boucle.socle.linux.io_uring.types import IoUringSqeFlags, IoUringAcceptFlags, IoUringBufReg, IoUringRegisterOp
from boucle.socle.linux.raw import IORING_RECV_MULTISHOT
from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.linux.raw import msghdr
from boucle.handle import RawHandle
from boucle.socle.ptr import null_ptr
from boucle.proactor.bufring import BufRing, _next_pow2, _IO_URING_BUF_SIZE
from boucle.proactor.completion import Completion
from boucle.drivers.driver import IoDriver


struct IoUringDriver(IoDriver):
    """IoDriver backed by Linux io_uring.

    Each submitted operation stores its Completion pointer as the SQE
    user_data. On CQE arrival, tick() recovers the pointer and fires
    the callback with the kernel result and flags.
    """

    var _ring: IoUring[]

    def __init__(out self, sq_entries: UInt32 = 64) raises:
        """Construct an IoUringDriver with the given SQ capacity.

        Args:
            sq_entries: Number of submission queue entries (default 64).
        """
        self._ring = IoUring[](sq_entries=sq_entries)

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._ring = move._ring^

    def tick(mut self, wait: Bool) raises:
        """Submit pending SQEs and dispatch completed operations.

        Recovers the Completion pointer from each CQE's user_data field
        and invokes the callback. Skips CQEs with user_data == 0 (e.g.
        internal kernel notifications).

        Args:
            wait: If True, block until at least one completion arrives.
                  If False, dispatch only already-available completions.
        """
        var wait_nr = UInt32(1) if wait else UInt32(0)
        _ = self._ring.submit_and_wait(wait_nr=wait_nr)
        var cq = self._ring.cq(wait_nr=0)
        while cq:
            var cqe = cq.__next__()
            if cqe.user_data == 0:
                continue
            var cmp = Pointer[Completion, MutAnyOrigin](
                unsafe_from_address=Int(cqe.user_data)
            )
            cmp[].fire(cqe.res, UInt32(cqe.flags.value))
        cq^.__deinit__()

    def submit_nop(
        mut self, c: Pointer[Completion, MutAnyOrigin]
    ) raises:
        """Queue a no-op operation with the given Completion token.

        Args:
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        _ = Nop(sq.__next__()).user_data(UInt64(Int(c)))

    def submit_connect(
        mut self,
        fd: RawHandle,
        addr: Pointer[UInt8, ImmStaticOrigin],
        addr_len: UInt64,
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a connect on socket `fd` to the given address.

        Args:
            fd: The socket file descriptor.
            addr: Pointer to the sockaddr structure.
            addr_len: Size in bytes of the sockaddr structure.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var addr_cv = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(addr)
        )
        _ = Connect(sq.__next__(), fd, addr_cv, addr_len).user_data(
            UInt64(Int(c))
        )

    def submit_timeout(
        mut self,
        ts: Pointer[NoneType, ImmStaticOrigin],
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a timeout (kernel timer).

        Args:
            ts: Opaque pointer to a 16-byte kernel_timespec.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var ts_cv = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(ts)
        )
        _ = Timeout(sq.__next__(), ts_cv).user_data(UInt64(Int(c)))

    def submit_cancel(
        mut self,
        target: Pointer[Completion, MutAnyOrigin],
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Matches the target by its Completion pointer (the user_data
        stored in the original SQE).

        Args:
            target: Pointer to the Completion of the op to cancel.
            c: Pointer to the Completion token for the cancel itself.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        _ = AsyncCancel(sq.__next__(), UInt64(Int(target))).user_data(
            UInt64(Int(c))
        )

    def submit_accept(
        mut self,
        fd: RawHandle,
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue an accept on listening socket `fd`.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        _ = Accept(sq.__next__(), fd).user_data(UInt64(Int(c)))

    def submit_recv(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutAnyOrigin],
        len: UInt32,
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a recv from socket `fd` into `buf`.

        Args:
            fd: The socket file descriptor.
            buf: Buffer to receive into. Must remain valid until CQE fires.
            len: Maximum bytes to receive.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var buf_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(buf)
        )
        _ = Recv(sq.__next__(), fd, buf_ptr, UInt(len)).user_data(
            UInt64(Int(c))
        )

    def submit_send(
        mut self,
        fd: RawHandle,
        buf: Pointer[UInt8, MutAnyOrigin],
        len: UInt32,
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a send on socket `fd` from `buf`.

        Args:
            fd: The socket file descriptor.
            buf: Data to send. Must remain valid until CQE fires.
            len: Number of bytes to send.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var buf_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(buf)
        )
        _ = Send(sq.__next__(), fd, buf_ptr, UInt(len)).user_data(
            UInt64(Int(c))
        )

    def submit_recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutAnyOrigin],
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a recvmsg on socket `fd`.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to msghdr (and all referenced buffers).
                 Must remain valid until CQE fires.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var msg_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(msg)
        )
        _ = RecvMsg(sq.__next__(), fd, msg_ptr).user_data(UInt64(Int(c)))

    def submit_sendmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[NoneType, MutAnyOrigin],
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a sendmsg on socket `fd`.

        Caller guarantees `msg` and all referenced buffers remain valid
        and unmodified until the corresponding CQE fires.

        Args:
            fd: The socket file descriptor.
            msg: Opaque pointer to msghdr with destination and payload.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var msg_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(msg)
        )
        _ = SendMsg(sq.__next__(), fd, msg_ptr).user_data(UInt64(Int(c)))

    def provide_buffers(
        mut self,
        buf_base: Pointer[UInt8, MutAnyOrigin],
        buf_size: Int,
        count: Int,
        group_id: UInt16,
        base_buf_id: UInt16,
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Register count contiguous buffers with io_uring.

        Buffers are contiguous: buf_base[i * buf_size .. (i+1) * buf_size].
        Each buffer gets ID base_buf_id + i.

        Args:
            buf_base: Base pointer for the contiguous buffer array.
            buf_size: Size of each individual buffer in bytes.
            count: Number of buffers to register.
            group_id: Buffer group ID to register under.
            base_buf_id: Starting buffer ID.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var buf_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(buf_base)
        )
        _ = ProvideBuffers(
            sq.__next__(),
            buf_ptr,
            UInt32(buf_size),
            UInt32(count),
            group_id,
            base_buf_id,
        ).user_data(UInt64(Int(c)))

    def submit_recv_multishot(
        mut self,
        fd: RawHandle,
        buf_group: UInt16,
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a multishot recv with provided buffer selection (TCP).

        The kernel selects a buffer from `buf_group` per arrival and
        produces one CQE per chunk. The payload begins at offset 0 of
        the chosen buffer (no io_uring_recvmsg_out header). The buffer
        ID is in CQE flags bits 16-31 when IORING_CQE_F_BUFFER is set.
        Re-arm when CQE flags lack IORING_CQE_F_MORE.

        Args:
            fd: The socket file descriptor.
            buf_group: The provided buffer group ID to select from.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var null_buf = null_ptr[c_void, ImmStaticOrigin]()
        _ = Recv(sq.__next__(), fd, null_buf, UInt(0))
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(UInt64(Int(c)))

    def submit_accept_multishot(
        mut self,
        fd: RawHandle,
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a multishot accept on listening socket `fd`.

        Produces one CQE per accepted connection. The CQE result is the
        accepted file descriptor (>= 0) on success. Re-arm when CQE
        flags lack IORING_CQE_F_MORE. Requires kernel >= 5.19.

        Args:
            fd: The listening socket file descriptor.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        _ = Accept(sq.__next__(), fd)
            .ioprio(IoUringAcceptFlags.MULTISHOT.value)
            .user_data(UInt64(Int(c)))

    def submit_multishot_recvmsg(
        mut self,
        fd: RawHandle,
        msg: Pointer[msghdr, MutAnyOrigin],
        buf_group: UInt16,
        c: Pointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a multishot recvmsg with provided buffer selection.

        Produces one CQE per received message. The buffer ID is in
        CQE flags bits 16-31 when IORING_CQE_F_BUFFER is set. The
        same Completion fires multiple times until the multishot ends
        (CQE without IORING_CQE_F_MORE flag). Caller must re-arm if
        desired.

        Args:
            fd: The socket file descriptor.
            msg: Pointer to msghdr template. Must remain valid for the
                 lifetime of the multishot operation.
            buf_group: The provided buffer group ID to select from.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var msg_ptr = Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(msg)
        )
        _ = RecvMsg(sq.__next__(), fd, msg_ptr)
            .ioprio(UInt16(IORING_RECV_MULTISHOT))
            .sqe_flags(IoUringSqeFlags.BUFFER_SELECT)
            .buf_group(buf_group)
            .user_data(UInt64(Int(c)))

    def sq_space(mut self) -> Int:
        """Return the number of available submission queue slots.

        Syncs the SQ head from the kernel and returns the count of
        entries available for new submissions.

        Returns:
            The number of SQ entries currently available for submission.
        """
        return len(self._ring.sq())

    def register_buf_ring(
        mut self,
        buf_base: Pointer[UInt8, MutAnyOrigin],
        buf_size: UInt32,
        count: Int,
        group_id: UInt16,
    ) raises -> BufRing:
        """Register a user-mapped provided-buffer ring (since kernel 5.19).

        Returning a consumed buffer to the ring is a userspace store on
        `BufRing.add_buffer(buf_id)` -- no SQE, no syscall, no kernel
        buffer-pool tree. Recommended for hot recv paths where the
        SQE-per-reprovide cost of the older `provide_buffers` path
        dominates.

        The ring requires a power-of-2 number of slots; `count` is
        rounded up if needed. Only `count` entries are populated,
        so `buf_base` must hold at least `count * buf_size` bytes.

        Args:
            buf_base: Base pointer for the data buffers.
            buf_size: Size of each individual data buffer in bytes.
            count: Number of buffers to populate.
            group_id: Buffer group ID to register under.

        Returns:
            A populated BufRing ready for multishot recv operations.
        """
        var entries = UInt32(_next_pow2(count))
        debug_assert(
            Int(entries) <= Int(UInt32.MAX) // _IO_URING_BUF_SIZE,
            "ring too large",
        )
        var ring_bytes = Int(entries) * _IO_URING_BUF_SIZE
        var ring_mem = _heap_alloc[UInt8](ring_bytes).as_unsafe_any_origin()
        for i in range(ring_bytes):
            ring_mem[unsafe_offset=i] = UInt8(0)

        var ring_mem_ut = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(ring_mem)
        )
        var buf_base_ut = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(buf_base)
        )
        var bring = BufRing(
            ring_mem_ut,
            entries,
            group_id,
            buf_base_ut,
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
        """Tear down a registered buffer ring.

        Args:
            group_id: The buffer group ID to unregister (use `BufRing.bgid`).
        """
        var reg = IoUringBufReg(bgid=group_id)
        var arg = reg.as_register_arg(
            unsafe_opcode=IoUringRegisterOp.UNREGISTER_PBUF_RING
        )
        _ = self._ring.register(arg)
