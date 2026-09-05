"""ConnectWithTimeoutFuture — composite connect+timeout via WatchLoop.

_ConnectWithTimeoutState manages 3 Completions (connect, timeout, cancel)
with dedicated static callbacks. Unlike simple Futures, this does NOT use
the generic _dispatch because each completion has different semantics.

The state machine resolves the operation once the first non-ECANCELED
result arrives on either connect or timeout, then cancels the other and
waits for all 3 completions before declaring done.

Cancel submission is deferred: callbacks set a flag, and WatchLoop.run()
calls flush_cancel() after each tick.

The state is shared with the WatchLoop that submitted it and follows the
ownership rules in `_callback.mojo`: it joins the loop's in-flight
registry as an _InFlightState. Dropping the ConnectWithTimeoutFuture
before all 3 completions have arrived is safe: the handle marks the state
as orphaned and the loop frees it once done, or when the loop itself is
destroyed. Destroying the loop first is also safe: the future frees the
state on drop and result() reports the destroyed loop. The static
callbacks never free the state — each one only knows about its own
completion, not whether the other two have arrived.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.drivers import _WatchDriver
from boucle.net.addr import SocketAddrStorAny
from boucle.proactor.completion import Completion
from boucle.timeout import Timeout
from boucle.watch._callback import _InFlightState, _SlotLink
from boucle.watch.outcome import ConnectOutcome
from boucle.socle.platform import ECANCELED


# ===----------------------------------------------------------------------=== #
# _ConnectWithTimeoutState — internal, slab-owned per-operation state
# ===----------------------------------------------------------------------=== #


struct _ConnectWithTimeoutState(_InFlightState):
    """State machine for a composite connect+timeout+cancel lifecycle.

    Owns 3 Completion tokens (connect, timeout, cancel) and resolves
    the operation when the first non-ECANCELED completion arrives on
    connect or timeout. The other operation is then cancelled via deferred
    flush_cancel(). Implements _InFlightState so the WatchLoop registry
    can settle its ownership like any simple state.

    Fields:
        _connect_cmp: Completion token for the connect operation.
        _timeout_cmp: Completion token for the timeout operation.
        _cancel_cmp: Completion token for the cancel operation.
        _addr_stor: Copy of the target address (IPv4 or IPv6) for
                    pointer stability.
        _ts: Timeout duration for operation pointer stability.
        _result: Raw completion result from the resolving callback.
        _result_set: True once a non-ECANCELED completion resolves the
                     operation.
        _resolved_by: 0=connect, 1=timeout.
        _cancel_target: 0=none, 1=cancel-timeout, 2=cancel-connect.
        _cancel_submitted: Whether cancel has been flagged.
        _total_completions: Number of completions received so far (done
                            when 3).
        done: True when all 3 completions have been received.
        consumed: True after result() has been called.
        _owner_dropped: True if the ConnectWithTimeoutFuture was dropped
                        before done; the WatchLoop then frees this state.
        _loop_gone: True if the WatchLoop was destroyed before done; the
                    ConnectWithTimeoutFuture then frees this state.
    """

    var _connect_cmp: Completion
    var _timeout_cmp: Completion
    var _cancel_cmp: Completion
    var _addr_stor: SocketAddrStorAny
    var _ts: Timeout
    var _result: Int
    var _result_set: Bool
    var _resolved_by: UInt8
    var _cancel_target: UInt8
    var _cancel_submitted: Bool
    var _total_completions: Int
    var done: Bool
    var consumed: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(
        out self,
        addr_stor: SocketAddrStorAny,
        ts: Timeout,
    ):
        """Construct state with address storage and timeout.

        All completions start as no-ops; the caller must wire invoke
        and context after heap allocation.

        Args:
            addr_stor: Copy of the target sockaddr (IPv4 or IPv6) for
                       pointer stability.
            ts: Timeout duration for the kernel timer.
        """
        self._connect_cmp = Completion()
        self._timeout_cmp = Completion()
        self._cancel_cmp = Completion()
        self._addr_stor = addr_stor
        self._ts = ts
        self._result = 0
        self._result_set = False
        self._resolved_by = UInt8(0)
        self._cancel_target = UInt8(0)
        self._cancel_submitted = False
        self._total_completions = 0
        self.done = False
        self.consumed = False
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

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
        self._result = move._result
        self._result_set = move._result_set
        self._resolved_by = move._resolved_by
        self._cancel_target = move._cancel_target
        self._cancel_submitted = move._cancel_submitted
        self._total_completions = move._total_completions
        self.done = move.done
        self.consumed = move.consumed
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def is_done(self) -> Bool:
        """Return True once all 3 completions have arrived.

        Returns:
            True if no callback will write this state again.
        """
        return self.done

    def owner_dropped(self) -> Bool:
        """Return True if the ConnectWithTimeoutFuture was dropped early.

        Returns:
            True if the WatchLoop must free this state.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        Returns:
            True if the ConnectWithTimeoutFuture is the sole remaining owner.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this composite in flight.
        """
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Record the slot this state lives in and the queue to notify.

        Args:
            link: The slot key and the loop's settle queue.
        """
        self._link = link

    def notify_done(self):
        """Tell the slot link the completion has arrived."""
        self._link.completed(self._owner_dropped)

    def mark_owner_dropped(mut self):
        """Record that the handle let go, and queue the slot if done."""
        self._owner_dropped = True
        self._link.dropped(self.done)

    def _check_done(mut self):
        """Mark operation as done when all 3 completions have arrived."""
        if self._total_completions >= 3:
            debug_assert(
                self._total_completions == 3, "completion count exceeded 3"
            )
            self.done = True
            self.notify_done()

    def flush_cancel(mut self, mut driver: _WatchDriver) raises -> Int:
        """Submit the deferred cancel operation if a callback requested one.

        Must be called after each tick() to ensure cancel operations
        are submitted outside of completion processing.

        Args:
            driver: The completion driver to submit the cancel operation on.

        Returns:
            Number of cancel operations submitted (0 or 1).
        """
        if self._cancel_target == UInt8(0):
            return 0

        if self._cancel_target == UInt8(1):
            var target_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=self._timeout_cmp))
            )
            var cancel_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=self._cancel_cmp))
            )
            driver.cancel(target_cmp_ptr, cancel_cmp_ptr)
        elif self._cancel_target == UInt8(2):
            var target_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=self._connect_cmp))
            )
            var cancel_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=self._cancel_cmp))
            )
            driver.cancel(target_cmp_ptr, cancel_cmp_ptr)

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
            result: The completion result reported by the backend.
            flags: The completion flags reported by the backend.
        """
        var self_ptr = Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[]._total_completions += 1

        if result == -Int(ECANCELED):
            self_ptr[]._check_done()
            return

        if self_ptr[]._result_set:
            self_ptr[]._check_done()
            return

        self_ptr[]._result = result
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
            result: The completion result reported by the backend.
            flags: The completion flags reported by the backend.
        """
        var self_ptr = Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[]._total_completions += 1

        if result == -Int(ECANCELED):
            self_ptr[]._check_done()
            return

        if self_ptr[]._result_set:
            self_ptr[]._check_done()
            return

        self_ptr[]._result = result
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

        Just counts the completion and checks done. The result value is
        irrelevant — -ENOENT, 0, -EALREADY are all acceptable.

        Args:
            ctx: Pointer to the owning _ConnectWithTimeoutState.
            result: The completion result reported by the backend (ignored).
            flags: The completion flags reported by the backend (ignored).
        """
        var self_ptr = Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[]._total_completions += 1
        self_ptr[]._check_done()


# ===----------------------------------------------------------------------=== #
# ConnectWithTimeoutFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct ConnectWithTimeoutFuture(Movable):
    """RAII handle for a composite connect+timeout operation.

    Points at a slab-owned _ConnectWithTimeoutState. Call done() to check
    completion, then result() to extract the ConnectOutcome.

    Dropping the handle before run() has delivered all three completions
    is safe: ownership of the state passes to the WatchLoop, which frees
    it once the composite is finished or when the loop is destroyed.
    Destroying the loop first is also safe (result() then raises).

    No fd cleanup needed on drop — connect modifies the existing socket
    in place, it does not produce a new fd.
    """

    var _state: Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin],
    ):
        """Construct a ConnectWithTimeoutFuture wrapping a slab-owned state.

        Args:
            state: Pointer to the slab-owned _ConnectWithTimeoutState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source ConnectWithTimeoutFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the loop has already been destroyed, this handle is the last
        reader of the state and destroys its contents here; the slot
        memory stays with the leaked slab. Otherwise the state is marked
        as orphaned and the loop's slab releases it — at the sweep after
        the last completion has arrived, or when the loop itself is
        destroyed.
        """
        if self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
        else:
            self._state[].mark_owner_dropped()

    def result(mut self) raises -> ConnectOutcome:
        """Decode the operation result into a ConnectOutcome.

        Timeout resolution uses ConnectOutcome.TIMEOUT directly.
        Connect resolution uses ConnectOutcome.from_result().

        Consumes the result — a second call raises. Does NOT raise
        on REFUSED/TIMEOUT — those are valid ConnectOutcome variants.

        Returns:
            A ConnectOutcome discriminating CONNECTED, REFUSED, TIMEOUT,
            NETWORK_UNREACHABLE, or ERROR.

        Raises:
            A plain message if the result was already consumed, the loop
            was destroyed before all completions arrived, or not all
            completions have arrived yet. A failed connect is not an
            exception here — it comes back as a ConnectOutcome.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            if self._state[]._loop_gone:
                raise "loop destroyed before completion"
            raise "operation not complete"
        self._state[].consumed = True
        if self._state[]._resolved_by == UInt8(1):
            return ConnectOutcome.TIMEOUT
        return ConnectOutcome.from_result(self._state[]._result)

    def done(self) -> Bool:
        """Return True when all 3 completions have been received.

        Stays False forever if the loop was destroyed first; result()
        then raises with the reason.

        Returns:
            True once the entire connect+timeout+cancel lifecycle
            is complete.
        """
        return self._state[].done
