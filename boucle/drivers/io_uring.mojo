"""Linux io_uring backend for the proactor IoDriver trait.

Wraps boucle's IoUring type and implements tick() (CQE dispatch via
Completion pointer recovery) and submit methods (nop, connect,
timeout, cancel).
"""

from std.memory import UnsafePointer

from std.memory.unsafe_pointer import alloc as _heap_alloc

from boucle._sys.linux.io_uring import IoUring
from boucle._sys.linux.io_uring.op import Nop, Connect, Accept, Recv, Send, RecvMsg, SendMsg, Timeout, AsyncCancel
from boucle._sys.linux.io_uring.types import IoUringSqeFlags, IoUringBufReg, IoUringRegisterOp
from boucle._sys.linux.raw import IORING_RECV_MULTISHOT
from boucle._sys.linux.raw.ctypes import c_void
from boucle._sys.linux.raw import msghdr
from boucle.handle import RawHandle
from boucle.proactor.bufring import BufRing, _next_pow2, _IO_URING_BUF_SIZE
from boucle.proactor.completion import Completion
from boucle.proactor.driver import IoDriver


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

    def __init__(out self, *, deinit take: Self):
        """Move constructor."""
        self._ring = take._ring^

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
            var cmp = UnsafePointer[Completion, MutAnyOrigin](
                unsafe_from_address=Int(cqe.user_data)
            )
            cmp[].fire(cqe.res, UInt32(cqe.flags.value))
        cq^.__del__()

    def submit_nop(
        mut self, c: UnsafePointer[Completion, MutAnyOrigin]
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
        addr: UnsafePointer[Int8, StaticConstantOrigin],
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
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        _ = Connect(sq.__next__(), fd, addr, addr_len).user_data(
            UInt64(Int(c))
        )

    def submit_timeout(
        mut self,
        ts: UnsafePointer[c_void, StaticConstantOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a timeout (kernel timer).

        Args:
            ts: Pointer to a 16-byte kernel_timespec.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        _ = Timeout(sq.__next__(), ts).user_data(UInt64(Int(c)))

    def submit_cancel(
        mut self,
        target: UnsafePointer[Completion, MutAnyOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
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
        c: UnsafePointer[Completion, MutAnyOrigin],
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
        buf: UnsafePointer[UInt8, MutAnyOrigin],
        len: UInt32,
        c: UnsafePointer[Completion, MutAnyOrigin],
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
        var buf_ptr = UnsafePointer[c_void, StaticConstantOrigin](
            unsafe_from_address=Int(buf)
        )
        _ = Recv(sq.__next__(), fd, buf_ptr, UInt(len)).user_data(
            UInt64(Int(c))
        )

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
            buf: Data to send. Must remain valid until CQE fires.
            len: Number of bytes to send.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var buf_ptr = UnsafePointer[c_void, StaticConstantOrigin](
            unsafe_from_address=Int(buf)
        )
        _ = Send(sq.__next__(), fd, buf_ptr, UInt(len)).user_data(
            UInt64(Int(c))
        )

    def submit_recvmsg(
        mut self,
        fd: RawHandle,
        msg: UnsafePointer[msghdr, MutAnyOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a recvmsg on socket `fd`.

        Args:
            fd: The socket file descriptor.
            msg: Pointer to msghdr (and all referenced buffers). Must
                 remain valid until CQE fires.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var msg_ptr = UnsafePointer[c_void, StaticConstantOrigin](
            unsafe_from_address=Int(msg)
        )
        _ = RecvMsg(sq.__next__(), fd, msg_ptr).user_data(UInt64(Int(c)))

    def submit_sendmsg(
        mut self,
        fd: RawHandle,
        msg: UnsafePointer[msghdr, MutAnyOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a sendmsg on socket `fd`.

        Caller guarantees `msg` and all referenced buffers remain valid
        and unmodified until the corresponding CQE fires.

        Args:
            fd: The socket file descriptor.
            msg: Pointer to msghdr with destination and payload.
            c: Pointer to the caller-owned Completion token.
        """
        if not self._ring.sq():
            raise "submission queue full"
        var sq = self._ring.unsynced_sq()
        var msg_ptr = UnsafePointer[c_void, StaticConstantOrigin](
            unsafe_from_address=Int(msg)
        )
        _ = SendMsg(sq.__next__(), fd, msg_ptr).user_data(UInt64(Int(c)))

    def submit_multishot_recvmsg(
        mut self,
        fd: RawHandle,
        msg: UnsafePointer[msghdr, MutAnyOrigin],
        buf_group: UInt16,
        c: UnsafePointer[Completion, MutAnyOrigin],
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
        var msg_ptr = UnsafePointer[c_void, StaticConstantOrigin](
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
        buf_base: UnsafePointer[UInt8, MutAnyOrigin],
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

        `count` must be a power of 2; if it isn't, it is rounded up.
        Allocates the ring and pre-fills `count` entries each pointing
        at `buf_base + i * buf_size` (i = 0..count-1).

        Args:
            buf_base: Base pointer for the data buffers.
            buf_size: Size of each individual data buffer in bytes.
            count: Number of buffers (rounded up to next power of 2).
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
        """Tear down a registered buffer ring.

        Args:
            group_id: The buffer group ID to unregister (use `BufRing.bgid`).
        """
        var reg = IoUringBufReg(bgid=group_id)
        var arg = reg.as_register_arg(
            unsafe_opcode=IoUringRegisterOp.UNREGISTER_PBUF_RING
        )
        _ = self._ring.register(arg)
