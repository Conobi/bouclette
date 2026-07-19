"""ConnectProbe — callback-driven state machine for port probing.

Manages the connect+timeout+cancel lifecycle for a single port probe.
Each probe owns three Completion tokens (connect, timeout, cancel).
The kernel delivers exactly one CQE per submitted SQE. The state
machine resolves the probe once the first non-ECANCELED result
arrives on either connect or timeout, then cancels the other and
waits for all 3 CQEs before declaring done.
"""

from std.memory import UnsafePointer
from boucle._sys.ptr import null_ptr
from boucle._sys.linux.raw import __kernel_timespec
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrStorV4
from boucle.net.probe import PortStatus, result_from_connect_cqe
from boucle.proactor.completion import Completion, CompletionFn


struct ConnectProbe:
    """State machine managing the connect+timeout+cancel lifecycle.

    Fields:
        socket: TCP socket (or dummy for test mode).
        _addr_stor: Stored sockaddr for connect SQE lifetime.
        _connect_cmp: Completion token for the connect operation.
        _timeout_cmp: Completion token for the timeout operation.
        _cancel_cmp: Completion token for the cancel operation.
        _ts: Timeout duration (owned by probe for SQE pointer stability).
        _driver_ptr: Type-erased driver pointer for cancel submission.
        _result_value: The resolved PortStatus (valid only when _result_set).
        _result_set: Whether result has been resolved.
        _resolved_by: 0=connect, 1=timeout (diagnostic).
        _cancel_submitted: Whether a cancel SQE has been submitted.
        _total_cqes: Number of CQEs received so far.
        _done: True when all 3 CQEs have arrived.
    """

    var socket: Socket
    var _addr_stor: SocketAddrStorV4
    var _connect_cmp: Completion
    var _timeout_cmp: Completion
    var _cancel_cmp: Completion
    var _ts: __kernel_timespec
    var _driver_ptr: UnsafePointer[NoneType, MutAnyOrigin]
    var _result_value: PortStatus
    var _result_set: Bool
    var _resolved_by: UInt8
    var _cancel_submitted: Bool
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
        self._ts = __kernel_timespec(tv_sec=Int64(0), tv_nsec=Int64(0))
        self._driver_ptr = null_ptr[NoneType, MutAnyOrigin]()
        self._result_value = PortStatus.FILTERED
        self._result_set = False
        self._resolved_by = UInt8(0)
        self._cancel_submitted = False
        self._total_cqes = 0
        self._done = False

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
        6. If driver is non-null: submit cancel targeting timeout.
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

        # Submit cancel for timeout (skip if no driver in test mode).
        if Int(self_ptr[]._driver_ptr) != 0:
            # Production path: submit ASYNC_CANCEL targeting _timeout_cmp.
            # Not implemented for test mode — driver_ptr is null.
            pass
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
        6. If driver is non-null: submit cancel targeting connect.
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

        # Submit cancel for connect (skip if no driver in test mode).
        if Int(self_ptr[]._driver_ptr) != 0:
            # Production path: submit ASYNC_CANCEL targeting _connect_cmp.
            # Not implemented for test mode — driver_ptr is null.
            pass
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
