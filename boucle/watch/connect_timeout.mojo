"""ConnectWithTimeoutFuture — composite connect+timeout via WatchLoop.

_ConnectWithTimeoutState manages 3 Completions (connect, timeout, cancel)
with dedicated static callbacks. Unlike simple Futures, this does NOT use
the generic _dispatch because each CQE has different semantics.

The state machine resolves the operation once the first non-ECANCELED
result arrives on either connect or timeout, then cancels the other and
waits for all 3 CQEs before declaring done.

Cancel submission is deferred: callbacks set a flag, and WatchLoop.run()
calls flush_cancel() after each tick.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.drivers.probe import ProbeCompletionDriver
from boucle.net.addr import SocketAddrStorV4
from boucle.proactor.completion import Completion
from boucle.timeout import Timeout
from boucle.watch.outcome import ConnectOutcome
from boucle.socle.linux.raw import ECANCELED


# ===----------------------------------------------------------------------=== #
# _ConnectWithTimeoutState — internal, heap-allocated per-operation state
# ===----------------------------------------------------------------------=== #


struct _ConnectWithTimeoutState(Movable):
    """State machine for a composite connect+timeout+cancel lifecycle.

    Owns 3 Completion tokens (connect, timeout, cancel) and resolves
    the operation when the first non-ECANCELED CQE arrives on connect
    or timeout. The other operation is then cancelled via deferred
    flush_cancel().

    Fields:
        _connect_cmp: Completion token for the connect operation.
        _timeout_cmp: Completion token for the timeout operation.
        _cancel_cmp: Completion token for the cancel operation.
        _addr_stor: Copy of the target address for pointer stability.
        _ts: Timeout duration for SQE pointer stability.
        _cqe_result: Raw CQE result from the resolving callback.
        _result_set: True once a non-ECANCELED CQE resolves the operation.
        _resolved_by: 0=connect, 1=timeout.
        _cancel_target: 0=none, 1=cancel-timeout, 2=cancel-connect.
        _cancel_submitted: Whether cancel has been flagged.
        _total_cqes: Number of CQEs received so far (done when 3).
        done: True when all 3 CQEs have been received.
        consumed: True after result() has been called.
    """

    var _connect_cmp: Completion
    var _timeout_cmp: Completion
    var _cancel_cmp: Completion
    var _addr_stor: SocketAddrStorV4
    var _ts: Timeout
    var _cqe_result: Int
    var _result_set: Bool
    var _resolved_by: UInt8
    var _cancel_target: UInt8
    var _cancel_submitted: Bool
    var _total_cqes: Int
    var done: Bool
    var consumed: Bool

    def __init__(
        out self,
        addr_stor: SocketAddrStorV4,
        ts: Timeout,
    ):
        """Construct state with address storage and timeout.

        All completions start as no-ops; the caller must wire invoke
        and context after heap allocation.

        Args:
            addr_stor: Copy of the target sockaddr for pointer stability.
            ts: Timeout duration for the kernel timer.
        """
        self._connect_cmp = Completion()
        self._timeout_cmp = Completion()
        self._cancel_cmp = Completion()
        self._addr_stor = addr_stor
        self._ts = ts
        self._cqe_result = 0
        self._result_set = False
        self._resolved_by = UInt8(0)
        self._cancel_target = UInt8(0)
        self._cancel_submitted = False
        self._total_cqes = 0
        self.done = False
        self.consumed = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source state to move from.
        """
        self._connect_cmp = move._connect_cmp^
        self._timeout_cmp = move._timeout_cmp^
        self._cancel_cmp = move._cancel_cmp^
        self._addr_stor = move._addr_stor
        self._ts = move._ts
        self._cqe_result = move._cqe_result
        self._result_set = move._result_set
        self._resolved_by = move._resolved_by
        self._cancel_target = move._cancel_target
        self._cancel_submitted = move._cancel_submitted
        self._total_cqes = move._total_cqes
        self.done = move.done
        self.consumed = move.consumed

    def _check_done(mut self):
        """Mark operation as done when all 3 CQEs have arrived."""
        if self._total_cqes >= 3:
            debug_assert(self._total_cqes == 3, "CQE count exceeded 3")
            self.done = True

    def flush_cancel(mut self, mut driver: ProbeCompletionDriver) raises -> Int:
        """Submit the deferred cancel SQE if a callback requested one.

        Must be called after each tick() to ensure cancel operations
        are submitted outside of CQE processing.

        Args:
            driver: The completion driver to submit the cancel SQE on.

        Returns:
            Number of cancel SQEs submitted (0 or 1).
        """
        if self._cancel_target == UInt8(0):
            return 0

        if self._cancel_target == UInt8(1):
            var target_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
                unsafe_from_address=Int(
                    Pointer(to=self._timeout_cmp)
                )
            )
            var cancel_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
                unsafe_from_address=Int(
                    Pointer(to=self._cancel_cmp)
                )
            )
            driver.submit_cancel(target_cmp_ptr, cancel_cmp_ptr)
        elif self._cancel_target == UInt8(2):
            var target_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
                unsafe_from_address=Int(
                    Pointer(to=self._connect_cmp)
                )
            )
            var cancel_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
                unsafe_from_address=Int(
                    Pointer(to=self._cancel_cmp)
                )
            )
            driver.submit_cancel(target_cmp_ptr, cancel_cmp_ptr)

        self._cancel_target = UInt8(0)
        return 1

    @staticmethod
    def _on_connect_cb(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Static callback for the connect completion.

        If ECANCELED: just count. If already resolved: just count.
        Otherwise: store result, flag cancel-timeout for deferred flush.

        Args:
            ctx: Pointer to the owning _ConnectWithTimeoutState.
            result: The io_uring CQE result.
            flags: The io_uring CQE flags.
        """
        var self_ptr = Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[]._total_cqes += 1

        if result == -Int(ECANCELED):
            self_ptr[]._check_done()
            return

        if self_ptr[]._result_set:
            self_ptr[]._check_done()
            return

        self_ptr[]._cqe_result = result
        self_ptr[]._result_set = True
        self_ptr[]._resolved_by = UInt8(0)

        debug_assert(
            not self_ptr[]._cancel_submitted, "no-double-cancel violated"
        )
        self_ptr[]._cancel_target = UInt8(1)
        self_ptr[]._cancel_submitted = True
        self_ptr[]._check_done()

    @staticmethod
    def _on_timeout_cb(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Static callback for the timeout completion.

        If ECANCELED: just count. If already resolved: just count.
        Otherwise: mark as TIMEOUT, flag cancel-connect for deferred flush.

        Args:
            ctx: Pointer to the owning _ConnectWithTimeoutState.
            result: The io_uring CQE result.
            flags: The io_uring CQE flags.
        """
        var self_ptr = Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[]._total_cqes += 1

        if result == -Int(ECANCELED):
            self_ptr[]._check_done()
            return

        if self_ptr[]._result_set:
            self_ptr[]._check_done()
            return

        self_ptr[]._cqe_result = result
        self_ptr[]._result_set = True
        self_ptr[]._resolved_by = UInt8(1)

        debug_assert(
            not self_ptr[]._cancel_submitted, "no-double-cancel violated"
        )
        self_ptr[]._cancel_target = UInt8(2)
        self_ptr[]._cancel_submitted = True
        self_ptr[]._check_done()

    @staticmethod
    def _on_cancel_cb(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Static callback for the cancel completion.

        Just counts the CQE and checks done. The result value is
        irrelevant — -ENOENT, 0, -EALREADY are all acceptable.

        Args:
            ctx: Pointer to the owning _ConnectWithTimeoutState.
            result: The io_uring CQE result (ignored).
            flags: The io_uring CQE flags (ignored).
        """
        var self_ptr = Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[]._total_cqes += 1
        self_ptr[]._check_done()


# ===----------------------------------------------------------------------=== #
# ConnectWithTimeoutFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct ConnectWithTimeoutFuture(Movable):
    """RAII handle for a composite connect+timeout operation.

    Owns a heap-allocated _ConnectWithTimeoutState. Call done() to check
    completion, then result() to extract the ConnectOutcome.

    No fd cleanup needed on drop — connect modifies the existing socket
    in place, it does not produce a new fd.
    """

    var _state: Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin],
    ):
        """Construct a ConnectWithTimeoutFuture wrapping a heap-allocated state.

        Args:
            state: Pointer to the heap-allocated _ConnectWithTimeoutState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source ConnectWithTimeoutFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the heap-allocated state."""
        self._state.unsafe_deinit_pointee()
        self._state.unsafe_free()

    def result(mut self) raises -> ConnectOutcome:
        """Decode the operation result into a ConnectOutcome.

        Timeout resolution uses ConnectOutcome.TIMEOUT directly.
        Connect resolution uses ConnectOutcome.from_cqe_result().

        Consumes the result — a second call raises. Does NOT raise
        on REFUSED/TIMEOUT — those are valid ConnectOutcome variants.

        Returns:
            A ConnectOutcome discriminating CONNECTED, REFUSED, TIMEOUT,
            NETWORK_UNREACHABLE, or ERROR.

        Raises:
            If the result was already consumed or not all CQEs have
            arrived yet.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            raise "operation not complete"
        self._state[].consumed = True
        if self._state[]._resolved_by == UInt8(1):
            return ConnectOutcome.TIMEOUT
        return ConnectOutcome.from_cqe_result(self._state[]._cqe_result)

    def done(self) -> Bool:
        """Return True when all 3 CQEs have been received.

        Returns:
            True once the entire connect+timeout+cancel lifecycle
            is complete.
        """
        return self._state[].done
