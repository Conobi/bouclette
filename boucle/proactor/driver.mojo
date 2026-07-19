"""Backend-agnostic I/O driver trait for the proactor.

Defines the interface that platform-specific I/O backends must
implement. Each method either submits work to the kernel or
dispatches completed operations via their Completion callbacks.
"""

from std.memory import UnsafePointer

from boucle.proactor.completion import Completion
from boucle.handle import RawHandle
from boucle._sys.linux.raw.ctypes import c_void


trait IoDriver(Movable):
    """Platform I/O backend abstraction.

    Implementors wrap a kernel async I/O mechanism (e.g. io_uring)
    and expose a uniform submit/tick interface consumed by the
    proactor event loop.
    """

    def __del__(deinit self):
        """Release all resources held by this driver."""
        ...

    def tick(mut self, wait: Bool) raises:
        """Submit pending SQEs and dispatch completed operations.

        Args:
            wait: If True, block until at least one completion arrives.
                  If False, return immediately after dispatching any
                  already-available completions.
        """
        ...

    def submit_nop(
        mut self, c: UnsafePointer[Completion, MutAnyOrigin]
    ) raises:
        """Queue a no-op operation.

        Args:
            c: Pointer to the caller-owned Completion token. Stored as
               SQE user_data; fired on CQE arrival.
        """
        ...

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
            addr: Pointer to the sockaddr structure (must remain valid
                  until completion fires).
            addr_len: Size in bytes of the sockaddr structure.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def submit_timeout(
        mut self,
        ts: UnsafePointer[c_void, StaticConstantOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Queue a timeout (kernel timer).

        Args:
            ts: Pointer to a 16-byte kernel_timespec (tv_sec i64 +
                tv_nsec i64). Must remain valid until completion fires.
            c: Pointer to the caller-owned Completion token.
        """
        ...

    def submit_cancel(
        mut self,
        target: UnsafePointer[Completion, MutAnyOrigin],
        c: UnsafePointer[Completion, MutAnyOrigin],
    ) raises:
        """Cancel a previously submitted operation.

        Matches the target by its Completion pointer (stored as
        user_data in the original SQE). The cancel itself produces
        a CQE on `c`; the cancelled target also produces a CQE with
        result == -ECANCELED if it was still in flight.

        Args:
            target: Pointer to the Completion of the operation to cancel.
            c: Pointer to the Completion token for the cancel operation
               itself.
        """
        ...

    def sq_space(mut self) -> Int:
        """Return the number of available submission queue slots.

        Callers use this to verify sufficient capacity before
        submitting multi-SQE atomic operations (e.g. connect +
        timeout that must both fit or neither is queued).

        Returns:
            The number of SQ entries currently available for submission.
        """
        ...
