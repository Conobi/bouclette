"""ConnectProbe — callback-driven state machine for port probing.

Manages the connect+timeout+cancel lifecycle for a single port probe.
Each probe owns three Completion tokens (connect, timeout, cancel).
The kernel delivers exactly one CQE per submitted SQE. The state
machine resolves the probe once the first non-ECANCELED result
arrives on either connect or timeout, then cancels the other and
waits for all 3 CQEs before declaring done.

Cancel submission is deferred: callbacks set a flag indicating which
operation to cancel, and the caller must invoke flush_cancel() after
each tick to submit the actual ASYNC_CANCEL SQE. This avoids a known
issue where SQEs queued during CQE processing are not reliably
picked up by the kernel on the next submit_and_wait.
"""

from std.memory import UnsafePointer
from boucle.socle.ptr import null_ptr
from boucle.timeout import Timeout
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.probe import PortStatus, result_from_connect_cqe
from boucle.proactor.completion import Completion, CompletionFn
from boucle.completion import CompletionLoop


struct ConnectProbe(Movable):
    """State machine managing the connect+timeout+cancel lifecycle.

    Fields:
        socket: TCP socket (or dummy for test mode).
        _addr_stor: Stored sockaddr for connect SQE lifetime.
        _connect_cmp: Completion token for the connect operation.
        _timeout_cmp: Completion token for the timeout operation.
        _cancel_cmp: Completion token for the cancel operation.
        _ts: Timeout value (owned by probe for SQE pointer stability).
        _driver_ptr: Type-erased loop pointer for cancel submission.
        _result_value: The resolved PortStatus (valid only when _result_set).
        _result_set: Whether result has been resolved.
        _resolved_by: 0=connect, 1=timeout (diagnostic).
        _cancel_submitted: Whether a cancel SQE has been submitted.
        _cancel_target: 0=none, 1=cancel-timeout, 2=cancel-connect.
        _total_cqes: Number of CQEs received so far.
        _done: True when all 3 CQEs have arrived.
    """

    var socket: Socket
    var _addr_stor: SocketAddrStorV4
    var _connect_cmp: Completion
    var _timeout_cmp: Completion
    var _cancel_cmp: Completion
    var _ts: Timeout
    var _driver_ptr: UnsafePointer[NoneType, MutAnyOrigin]
    var _result_value: PortStatus
    var _result_set: Bool
    var _resolved_by: UInt8
    var _cancel_submitted: Bool
    var _cancel_target: UInt8
    var _total_cqes: Int
    var _done: Bool

    @staticmethod
    def for_test() raises -> Self:
        """Create a probe in test mode without a real driver.

        Creates a real TCP socket (socket() syscall only, no io_uring)
        but sets driver_ptr to null so callbacks skip cancel submission.

        Returns:
            A ConnectProbe suitable for unit testing state transitions.
        """
        return Self()

    def __init__(out self) raises:
        """Construct a ConnectProbe with default (unresolved) state.

        Creates a TCP socket internally. All completion tokens start
        as no-ops; call wire_context() to set up callbacks before use.
        """
        self.socket = Socket.tcp_v4()
        self._addr_stor = SocketAddrStorV4()
        self._connect_cmp = Completion()
        self._timeout_cmp = Completion()
        self._cancel_cmp = Completion()
        self._ts = Timeout(seconds=Int64(0), nanoseconds=Int64(0))
        self._driver_ptr = null_ptr[NoneType, MutAnyOrigin]()
        self._result_value = PortStatus.FILTERED
        self._result_set = False
        self._resolved_by = UInt8(0)
        self._cancel_submitted = False
        self._cancel_target = UInt8(0)
        self._total_cqes = 0
        self._done = False

    def __init__(out self, *, target: SocketAddrV4, timeout_ms: Int) raises:
        """Construct a ConnectProbe for a specific target and timeout.

        Creates a TCP socket, stores the target address for SQE pointer
        stability, and configures the timeout duration. Call wire_context()
        then submit() to begin the probe lifecycle.

        Args:
            target: The IPv4 address and port to probe.
            timeout_ms: Timeout in milliseconds before declaring FILTERED.
        """
        self.socket = Socket.tcp_v4()
        self._addr_stor = target.addr_stor()
        self._connect_cmp = Completion()
        self._timeout_cmp = Completion()
        self._cancel_cmp = Completion()
        self._ts = Timeout.from_ms(Int64(timeout_ms))
        self._driver_ptr = null_ptr[NoneType, MutAnyOrigin]()
        self._result_value = PortStatus.FILTERED
        self._result_set = False
        self._resolved_by = UInt8(0)
        self._cancel_submitted = False
        self._cancel_target = UInt8(0)
        self._total_cqes = 0
        self._done = False

    def __init__(out self, *, deinit take: Self):
        """Move constructor.

        Args:
            take: The source ConnectProbe to move from.
        """
        self.socket = take.socket^
        self._addr_stor = take._addr_stor
        self._connect_cmp = take._connect_cmp^
        self._timeout_cmp = take._timeout_cmp^
        self._cancel_cmp = take._cancel_cmp^
        self._ts = take._ts
        self._driver_ptr = take._driver_ptr
        self._result_value = take._result_value
        self._result_set = take._result_set
        self._resolved_by = take._resolved_by
        self._cancel_submitted = take._cancel_submitted
        self._cancel_target = take._cancel_target
        self._total_cqes = take._total_cqes
        self._done = take._done

    def wire_context(mut self):
        """Wire completion context pointers and callbacks to self.

        Must be called after construction and before any CQE can fire.
        Sets each Completion's context to point to this probe and assigns
        the appropriate static callback function.
        """
        var self_ptr = UnsafePointer[NoneType, MutAnyOrigin](
            unsafe_from_address=Int(UnsafePointer(to=self))
        )
        self._connect_cmp.context = self_ptr
        self._connect_cmp.invoke = Self._on_connect_cb
        self._timeout_cmp.context = self_ptr
        self._timeout_cmp.invoke = Self._on_timeout_cb
        self._cancel_cmp.context = self_ptr
        self._cancel_cmp.invoke = Self._on_cancel_cb

    def submit(mut self, mut loop: CompletionLoop) raises:
        """Submit connect + timeout SQEs to the completion loop.

        Requires at least 2 SQ slots available for the atomic pair
        (connect + timeout). Stores the loop pointer so flush_cancel()
        can submit the cancel SQE after a resolving CQE fires.

        Args:
            loop: The opaque CompletionLoop.

        Raises:
            If insufficient SQ space is available for the atomic submit.
        """
        if loop.sq_space() < 2:
            raise "insufficient SQ space for atomic submit"

        # Store loop pointer for cancel submission via flush_cancel.
        self._driver_ptr = UnsafePointer[NoneType, MutAnyOrigin](
            unsafe_from_address=Int(UnsafePointer(to=loop))
        )

        # Submit connect SQE.
        var addr_ptr = self._addr_stor.addr_unsafe_ptr()
        var addr_len = UInt64(SocketAddrStorV4.ADDR_LEN)
        var connect_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
            unsafe_from_address=Int(UnsafePointer(to=self._connect_cmp))
        )
        loop.submit_connect(
            self.socket.raw(), addr_ptr, addr_len, connect_cmp_ptr
        )

        # Submit timeout SQE.
        var ts_ptr = UnsafePointer[NoneType, StaticConstantOrigin](
            unsafe_from_address=Int(UnsafePointer(to=self._ts))
        )
        var timeout_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
            unsafe_from_address=Int(UnsafePointer(to=self._timeout_cmp))
        )
        loop.submit_timeout(ts_ptr, timeout_cmp_ptr)

    def flush_cancel(mut self, mut loop: CompletionLoop) raises:
        """Submit the deferred cancel SQE if a callback requested one.

        Must be called after each run_once() to ensure cancel operations
        are submitted outside of CQE processing. SQEs queued during CQE
        callbacks are not reliably picked up by io_uring's next
        submit_and_wait; this method submits them from the caller's
        context where flushing is deterministic.

        Args:
            loop: The opaque CompletionLoop.

        Raises:
            If the submission queue is full (non-fatal in practice).
        """
        if self._cancel_target == UInt8(0):
            return

        if self._cancel_target == UInt8(1):
            # Cancel the timeout.
            var target_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
                unsafe_from_address=Int(
                    UnsafePointer(to=self._timeout_cmp)
                )
            )
            var cancel_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
                unsafe_from_address=Int(
                    UnsafePointer(to=self._cancel_cmp)
                )
            )
            loop.submit_cancel(target_cmp_ptr, cancel_cmp_ptr)
        elif self._cancel_target == UInt8(2):
            # Cancel the connect.
            var target_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
                unsafe_from_address=Int(
                    UnsafePointer(to=self._connect_cmp)
                )
            )
            var cancel_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
                unsafe_from_address=Int(
                    UnsafePointer(to=self._cancel_cmp)
                )
            )
            loop.submit_cancel(target_cmp_ptr, cancel_cmp_ptr)

        # Clear the flag so we don't double-submit.
        self._cancel_target = UInt8(0)

    @always_inline
    def is_done(self) -> Bool:
        """Return True when all 3 CQEs have been received.

        Returns:
            Whether the probe lifecycle is complete.
        """
        return self._done

    @always_inline
    def result_is_set(self) -> Bool:
        """Return True if the probe result has been resolved.

        Returns:
            Whether a definitive PortStatus has been determined.
        """
        return self._result_set

    @always_inline
    def result_status(self) -> PortStatus:
        """Return the resolved PortStatus.

        Precondition: result_is_set() must be True.

        Returns:
            The PortStatus determined by the first resolving callback.
        """
        return self._result_value

    def _check_done(mut self):
        """Mark probe as done if all 3 CQEs have arrived."""
        if self._total_cqes >= 3:
            debug_assert(self._total_cqes == 3, "CQE count exceeded 3")
            self._done = True

    @staticmethod
    def _on_connect_cb(
        ctx: UnsafePointer[NoneType, MutAnyOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Static callback for the connect completion.

        State machine logic:
        1. Increment _total_cqes.
        2. If result == -125 (ECANCELED): check_done, return.
        3. If result already set: check_done, return (dual-fire guard).
        4. Set result from connect CQE result code.
        5. Set _resolved_by = 0.
        6. Set _cancel_target = 1 (cancel-timeout) for deferred flush.
        7. Set _cancel_submitted = True.

        Args:
            ctx: Pointer to the owning ConnectProbe (type-erased).
            result: The io_uring CQE result.
            flags: The io_uring CQE flags.
        """
        var self_ptr = UnsafePointer[ConnectProbe, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[]._total_cqes += 1

        # ECANCELED: the connect was cancelled by the other path.
        if result == Int32(-125):
            self_ptr[]._check_done()
            return

        # Dual-fire guard: result already resolved.
        if self_ptr[]._result_set:
            self_ptr[]._check_done()
            return

        # Resolve: map CQE result to PortStatus.
        self_ptr[]._result_value = result_from_connect_cqe(result)
        self_ptr[]._result_set = True
        self_ptr[]._resolved_by = UInt8(0)

        # Defer cancel for timeout (flush_cancel submits it after tick).
        debug_assert(
            not self_ptr[]._cancel_submitted, "no-double-cancel violated"
        )
        if Int(self_ptr[]._driver_ptr) != 0:
            self_ptr[]._cancel_target = UInt8(1)
        self_ptr[]._cancel_submitted = True
        self_ptr[]._check_done()

    @staticmethod
    def _on_timeout_cb(
        ctx: UnsafePointer[NoneType, MutAnyOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Static callback for the timeout completion.

        State machine logic:
        1. Increment _total_cqes.
        2. If result == -125 (ECANCELED): check_done, return.
        3. If result already set: check_done, return (dual-fire guard).
        4. Set result = FILTERED.
        5. Set _resolved_by = 1.
        6. Set _cancel_target = 2 (cancel-connect) for deferred flush.
        7. Set _cancel_submitted = True.

        Args:
            ctx: Pointer to the owning ConnectProbe (type-erased).
            result: The io_uring CQE result.
            flags: The io_uring CQE flags.
        """
        var self_ptr = UnsafePointer[ConnectProbe, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[]._total_cqes += 1

        # ECANCELED: the timeout was cancelled by the other path.
        if result == Int32(-125):
            self_ptr[]._check_done()
            return

        # Dual-fire guard: result already resolved.
        if self_ptr[]._result_set:
            self_ptr[]._check_done()
            return

        # Resolve: timeout means FILTERED.
        self_ptr[]._result_value = PortStatus.FILTERED
        self_ptr[]._result_set = True
        self_ptr[]._resolved_by = UInt8(1)

        # Defer cancel for connect (flush_cancel submits it after tick).
        debug_assert(
            not self_ptr[]._cancel_submitted, "no-double-cancel violated"
        )
        if Int(self_ptr[]._driver_ptr) != 0:
            self_ptr[]._cancel_target = UInt8(2)
        self_ptr[]._cancel_submitted = True
        self_ptr[]._check_done()

    @staticmethod
    def _on_cancel_cb(
        ctx: UnsafePointer[NoneType, MutAnyOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Static callback for the cancel completion.

        Simply increments the CQE count and checks done. The result
        value is irrelevant — -ENOENT, 0, -EALREADY are all acceptable.

        Args:
            ctx: Pointer to the owning ConnectProbe (type-erased).
            result: The io_uring CQE result (ignored).
            flags: The io_uring CQE flags (ignored).
        """
        var self_ptr = UnsafePointer[ConnectProbe, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[]._total_cqes += 1
        self_ptr[]._check_done()
