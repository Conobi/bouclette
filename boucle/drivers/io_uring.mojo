"""Linux io_uring backend for the proactor IoDriver trait.

Wraps boucle's IoUring type and implements tick() (CQE dispatch via
Completion pointer recovery) and submit methods (nop, connect,
timeout, cancel).
"""

from std.memory import UnsafePointer

from boucle._sys.linux.io_uring import IoUring
from boucle._sys.linux.io_uring.op import Nop, Connect, Timeout, AsyncCancel
from boucle._sys.linux.raw.ctypes import c_void
from boucle.handle import RawHandle
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

    def sq_space(mut self) -> Int:
        """Return the number of available submission queue slots.

        Syncs the SQ head from the kernel and returns the count of
        entries available for new submissions.

        Returns:
            The number of SQ entries currently available for submission.
        """
        return len(self._ring.sq())
