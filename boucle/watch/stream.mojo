"""`DatagramStream` — a multishot recvmsg that delivers into a `BufferPool`.

`_StreamState` owns the long-lived operation: its `Completion`, the
msghdr template (28-byte name slot, requested control capacity, one
zero-length iov), the internal cancel `Completion`, and a queue of
deliveries not yet taken. `DatagramStream` is the handle; `Datagram` is
one delivery, a `LeasedBuffer` plus the decoded header.

Termination policy per completion: MORE set and result >= 0 enqueues and
stays armed; no MORE and result >= 0 enqueues and queues a re-arm on the
loop's deferred list (a re-arm the driver refuses only because its
submission queue is momentarily full is retried at the next flush; any
other refusal disarms with that error); result < 0 while the handle is
held disarms the stream and sets `error()` (ENOBUFS is the expected
case, re-arm after returning leases); result < 0 after the handle
dropped is the terminal completion and settles the slot. Dropping an armed stream queues an
internal cancel whose own result is ignored; completions arriving in
between return their buffer to the pool instead of queueing. The
terminal and the cancel's own completion may land in either order (on
io_uring the cancel's CQE can precede the target's -ECANCELED); the
second one settles the slot, exactly once. Once the loop is gone the
handle is inert.

Mixing a one-shot `recv_msg` with an armed stream on the same socket is
undefined: the two race for datagrams on both backends.
"""

from std.collections import Optional
from std.memory import Pointer
from std.sys.info import size_of

from boucle.drivers import _WatchDriver
from boucle.error import IOError
from boucle.handle import RawHandle
from boucle.net.addr import (
    SocketAddrStorV4,
    SocketAddrStorV6,
    SocketAddrV4,
    SocketAddrV6,
)
from boucle.net.message import ControlMessages, DeliveryHeader
from boucle.net.options import AddrFamily
from boucle.proactor.completion import Completion, buffer_id, has_more
from boucle.socle.platform import (
    EAFNOSUPPORT,
    MSG_CTRUNC,
    MSG_TRUNC,
    iovec,
    msghdr,
    sockaddr_in,
    sockaddr_in6,
)
from boucle.watch._callback import _InFlightState, _SlotLink
from boucle.watch._shared import _LoopShared
from boucle.watch.pool import _PoolState, LeasedBuffer


# Name slot capacity of every stream: the largest supported sockaddr.
comptime _NAME_CAPACITY = size_of[sockaddr_in6]()


def _is_queue_full(e: Error) -> Bool:
    """Return True when the driver refused a submission only because its queue is full.

    The io_uring driver reports a submission queue still full after its
    flush as EAGAIN in socle's negated-errno text; that is the one
    refusal a stream retries at the next flush instead of disarming.
    Any other errno, and any text that is not an errno, is a genuine
    driver error.

    Args:
        e: The error the driver raised.

    Returns:
        True for `-EAGAIN`; False for anything else.
    """
    return IOError.from_error(e).is_would_block()


@fieldwise_init
struct _Delivery(ImplicitlyCopyable, Movable):
    """One completed delivery waiting to be taken.

    Fields:
        buf_id: The provided buffer the delivery landed in.
        result: The completion result (bytes written into the buffer).
        flags: The completion flags as the driver encoded them.
    """

    var buf_id: UInt16
    var result: Int
    var flags: UInt32


# ===----------------------------------------------------------------------=== #
# _StreamState — internal, slab-owned
# ===----------------------------------------------------------------------=== #


struct _StreamState(_InFlightState):
    """Slab-owned state of one multishot recvmsg stream.

    Fields:
        completion: Token of the multishot operation; fires once per delivery.
        cancel_completion: Token of the internal cancel submitted on drop.
        _msg: msghdr template (name capacity, control capacity, iov).
        _iov: The template's single zero-length iov.
        fd: The socket, kept for re-arms.
        group_id: The pool's driver group.
        control_capacity: Control bytes reserved in every buffer.
        pool: The pool deliveries lease from.
        deliveries: Completed deliveries not yet taken, oldest first.
        armed: True while the caller may expect deliveries (an operation
               is in flight or a re-arm is pending).
        error: Set when the stream ended on an error while held.
        rearm_requested: A re-arm waits on the deferred list.
        cancel_requested: A cancel waits on the deferred list.
        cancel_submitted: The cancel was handed to the driver.
        cancel_done: The cancel's own completion arrived.
        cancel_failed: The driver refused the cancel for a genuine error;
                       the slot waits for the operation to end on its own.
        pool_detached: This stream no longer counts against the pool.
        _finished: The slot key was pushed on the settle queue.
        _live_counted: The slab still counts this state live.
        _deferred_queued: The slot key is on the deferred list.
        _shared: The loop's shared box.
        _owner_dropped: The `DatagramStream` handle is gone.
        _loop_gone: The loop was destroyed with this stream in flight.
        _link: The slot this state lives in and the loop's settle queue.
    """

    var completion: Completion
    var cancel_completion: Completion
    var _msg: msghdr
    var _iov: iovec
    var fd: RawHandle
    var group_id: UInt16
    var control_capacity: Int
    var pool: Pointer[_PoolState, MutUntrackedOrigin]
    var deliveries: List[_Delivery]
    var armed: Bool
    var error: Optional[IOError]
    var rearm_requested: Bool
    var cancel_requested: Bool
    var cancel_submitted: Bool
    var cancel_done: Bool
    var cancel_failed: Bool
    var pool_detached: Bool
    var _finished: Bool
    var _live_counted: Bool
    var _deferred_queued: Bool
    var _shared: Pointer[_LoopShared, MutUntrackedOrigin]
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(
        out self,
        fd: RawHandle,
        group_id: UInt16,
        control_capacity: Int,
        pool: Pointer[_PoolState, MutUntrackedOrigin],
        shared: Pointer[_LoopShared, MutUntrackedOrigin],
    ):
        """Construct an armed stream state; call `wire()` once it is in its slot.

        Both completion tokens are left unwired and the msghdr's iov
        pointer unset: all three name addresses inside this state, which
        is only known once the state sits in its slab slot.

        Args:
            fd: The datagram socket.
            group_id: The pool's driver group.
            control_capacity: Control bytes to reserve per delivery.
            pool: The pool state deliveries lease from.
            shared: The loop's shared box.
        """
        self.completion = Completion()
        self.cancel_completion = Completion()
        self._msg = msghdr()
        self._msg.msg_namelen = UInt32(_NAME_CAPACITY)
        self._msg.msg_controllen = UInt64(control_capacity)
        self._msg.msg_iovlen = UInt64(1)
        self._iov = iovec()
        self.fd = fd
        self.group_id = group_id
        self.control_capacity = control_capacity
        self.pool = pool
        self.deliveries = List[_Delivery]()
        self.armed = True
        self.error = None
        self.rearm_requested = False
        self.cancel_requested = False
        self.cancel_submitted = False
        self.cancel_done = False
        self.cancel_failed = False
        self.pool_detached = False
        self._finished = False
        self._live_counted = True
        self._deferred_queued = False
        self._shared = shared
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        The msghdr pointer and the completion contexts are not rebased:
        `wire()` runs after the move into the slot, never before.

        Args:
            move: The source state.
        """
        self.completion = move.completion^
        self.cancel_completion = move.cancel_completion^
        self._msg = move._msg
        self._iov = move._iov
        self.fd = move.fd
        self.group_id = move.group_id
        self.control_capacity = move.control_capacity
        self.pool = move.pool
        self.deliveries = move.deliveries^
        self.armed = move.armed
        self.error = move.error
        self.rearm_requested = move.rearm_requested
        self.cancel_requested = move.cancel_requested
        self.cancel_submitted = move.cancel_submitted
        self.cancel_done = move.cancel_done
        self.cancel_failed = move.cancel_failed
        self.pool_detached = move.pool_detached
        self._finished = move._finished
        self._live_counted = move._live_counted
        self._deferred_queued = move._deferred_queued
        self._shared = move._shared
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def __deinit__(deinit self):
        """Return any queued lease and drop the pool reference.

        Both go through `pool[]`, which is valid because the pool
        outlives every stream that references it: a pool state cannot
        settle while `streams > 0`, so the sweep frees a stream slot
        while its pool is still registered, and at loop destruction the
        pool slab is detached after the stream slab. In the normal path
        `_finish` already did both and this is a no-op.
        """
        self._return_queued_leases()
        self._detach_pool()

    def wire(mut self):
        """Point the msghdr's iov field and both completions at this slot.

        Must run after the state is in its slab slot and before the
        operation is submitted: the addresses it records are those of
        the slot, which never moves. The delivery completion fires once
        per datagram; the cancel completion fires once, for the internal
        cancel submitted when the handle is dropped while armed.
        """
        self._msg.msg_iov = UInt64(Int(Pointer(to=self._iov)))
        var ctx = Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self))
        )
        self.completion = Completion(Self._on_delivery, ctx)
        self.cancel_completion = Completion(Self._on_cancel_cb, ctx)

    def msg_ptr(mut self) -> Pointer[NoneType, MutUntrackedOrigin]:
        """Return the opaque pointer to the msghdr template for the driver."""
        return Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._msg))
        )

    def completion_ptr(mut self) -> Pointer[Completion, MutUntrackedOrigin]:
        """Return the pointer to the multishot Completion for the driver."""
        return Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self.completion))
        )

    def cancel_ptr(mut self) -> Pointer[Completion, MutUntrackedOrigin]:
        """Return the pointer to the cancel Completion for the driver."""
        return Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self.cancel_completion))
        )

    def _return_queued_leases(mut self):
        """Give every queued delivery's buffer back to the pool."""
        for i in range(len(self.deliveries)):
            self.pool[].return_lease(self.deliveries[i].buf_id)
        self.deliveries.clear()

    def _detach_pool(mut self):
        """Stop counting against the pool (once)."""
        if not self.pool_detached:
            self.pool_detached = True
            self.pool[].detach_stream()

    def _queue_deferred(mut self):
        """Push the slot key on the loop's deferred list (once per flush)."""
        if not self._deferred_queued:
            self._deferred_queued = True
            self._shared[].deferred[].append(self._link.key)

    def _release_live_and_queue(mut self):
        """Push the slot key exactly once; the owner is already gone.

        A state that still counts live stops counting and queues in one
        step; one that already stopped (it ended on an error while held)
        only queues.
        """
        if self._live_counted:
            self._live_counted = False
            self._link.completed(True)
        else:
            self._link.dropped(True)

    def _finish(mut self):
        """Owner dropped and nothing will fire again: settle the slot (once).

        Idempotent: the terminal completion and the cancel's own
        completion each try to finish the stream when they arrive
        second, and on io_uring their order is not fixed. Only the first
        call pushes the slot key. The stream's key is queued before the
        pool is detached, so when the detach makes the pool reclaimable
        its key follows the stream's and the sweep releases the stream
        first: a pool always outlives the streams that reference it.
        """
        if self._finished:
            return
        self._finished = True
        self._return_queued_leases()
        self._release_live_and_queue()
        self._detach_pool()

    def _disarm(mut self, err: IOError):
        """End the stream on an error while the handle is held.

        The state stops counting live but is not queued: the handle
        still reads `error` and may re-arm.

        Args:
            err: The error `error()` will report.
        """
        self.armed = False
        self.error = err
        if self._live_counted:
            self._live_counted = False
            self._link.completed(False)

    def _on_op_ended(mut self):
        """The operation is no longer in flight and the owner is gone.

        Finishes now unless a cancel was submitted whose completion has
        not arrived yet; that completion finishes the stream instead. A
        cancel still waiting on the deferred list is dropped: there is
        nothing left to cancel and the flush ignores a cleared request.
        """
        self.armed = False
        if self.cancel_requested and not self.cancel_submitted:
            self.cancel_requested = False
        if self.cancel_submitted and not self.cancel_done:
            return
        self._finish()

    def _cancel_refused(mut self):
        """Give up on cancelling; the slot waits for the operation to end.

        The refusal proves nothing about the multishot itself, which may
        still be armed kernel-side and can complete into this slot at
        any time. So the state stays armed and `is_done()` stays False:
        the slot is never settled here. The cancel is not retried either
        (a genuine error would only repeat), so the slot stays allocated
        until the operation ends on its own, when the terminal
        completion settles it through `_on_op_ended` exactly as if no
        cancel had been asked for; failing that, it stays allocated for
        the life of the loop and the destructor releases it once the
        driver, and with it any chance of a completion, is gone.
        """
        self.cancel_requested = False
        self.cancel_submitted = False
        self.cancel_failed = True

    def flush_deferred(mut self, mut driver: _WatchDriver):
        """Submit the deferred cancel or re-arm, whichever is requested.

        Called by the loop outside completion processing. A cancel takes
        priority over a re-arm: once the handle is gone nothing must be
        resubmitted. A cancel refused because the submission queue is
        still full after the driver's own flush (`_is_queue_full`) stays
        requested and re-queues the key for the next flush. A cancel
        refused for any other reason is given up on (`_cancel_refused`):
        the operation may still be armed, so settling the slot would
        let a later completion write into freed or reused memory. The
        slot is kept instead, a bounded leak for the loop's life at
        worst, and settles when the operation ends on its own. A re-arm
        refused because the queue is full stays requested and re-queues
        the key the same way; any other driver error ends the stream
        with that error set.

        Args:
            driver: The loop's driver.
        """
        self._deferred_queued = False
        if self.cancel_requested:
            try:
                driver.cancel(self.completion_ptr(), self.cancel_ptr())
                self.cancel_requested = False
                self.cancel_submitted = True
            except e:
                if _is_queue_full(e):
                    self._queue_deferred()
                else:
                    self._cancel_refused()
            return
        if self.rearm_requested:
            try:
                driver.multishot_recvmsg(
                    self.fd,
                    self.msg_ptr(),
                    self.group_id,
                    self.completion_ptr(),
                )
                self.rearm_requested = False
            except e:
                self._rearm_refused(e)

    def _rearm_refused(mut self, e: Error):
        """Handle a re-arm the driver refused.

        A submission queue still full after the driver's own flush
        (`_is_queue_full`) keeps the re-arm requested and re-queues the
        key for the next flush. Any other error ends the stream with
        that error set: the request is dropped and the state disarmed.

        Args:
            e: The error the driver raised.
        """
        if _is_queue_full(e):
            self._queue_deferred()
        else:
            self.rearm_requested = False
            self._disarm(IOError.from_error(e))

    @staticmethod
    def _on_delivery(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """Completion callback of the multishot operation.

        Applies the termination policy in the module docstring. Never
        frees the state; the sweep does that once the key is queued.

        Every completion is tallied in the shared box so the loop does
        not subtract it from `_pending`. Once the handle has dropped no
        completion of the stream can be observed, so every one of them
        counts as internal: a delivery is recycled straight into the
        pool, and the terminal only settles the slot. While the handle
        is held every completion counts as a stream completion, except
        a delivery naming a buffer id past the pool: that buffer is
        never dereferenced, the delivery is dropped (the buffer it names
        is leaked) and counted as internal, and only the more-flag is
        honoured.

        Args:
            ctx: Pointer to the owning `_StreamState`.
            result: Bytes written into the selected buffer, or -errno.
            flags: Buffer id and more-flag as the driver encodes them.
        """
        var st = ctx.unsafe_bitcast[_StreamState]()
        var more = has_more(flags)
        if st[]._owner_dropped:
            st[]._shared[].internal_completions += 1
            if result >= 0:
                var bid = buffer_id(flags)
                if bid:
                    st[].pool[].recycle(bid.value())
                if more:
                    return
            st[]._on_op_ended()
            return
        if result >= 0:
            var bid = buffer_id(flags)
            var dropped = False
            if bid:
                if st[].pool[].holds(bid.value()):
                    st[].pool[].lease_taken()
                    st[].deliveries.append(
                        _Delivery(bid.value(), result, flags)
                    )
                else:
                    dropped = True
            if dropped:
                st[]._shared[].internal_completions += 1
            else:
                st[]._shared[].stream_completions += 1
            if more:
                return
            st[].rearm_requested = True
            st[]._queue_deferred()
            return
        st[]._shared[].stream_completions += 1
        st[]._disarm(IOError.from_errno(result))

    @staticmethod
    def _on_cancel_cb(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """Completion callback of the internal cancel.

        The result is ignored: 0, -ENOENT and -EALREADY are all fine.
        Counted as internal so `step()` does not report it. If the
        multishot's terminal completion already arrived, the stream
        finishes here; otherwise the terminal finishes it through
        `_on_op_ended`, whose wait on `cancel_done` is now satisfied.

        Args:
            ctx: Pointer to the owning `_StreamState`.
            result: The cancel's own result (ignored).
            flags: The cancel's flags (ignored).
        """
        var st = ctx.unsafe_bitcast[_StreamState]()
        st[]._shared[].internal_completions += 1
        st[].cancel_done = True
        if not st[].armed:
            st[]._finish()

    # ── _InFlightState ───────────────────────────────────────────────────

    def is_done(self) -> Bool:
        """Return True when no completion can write this state again."""
        return not self.armed and not (
            self.cancel_submitted and not self.cancel_done
        )

    def owner_dropped(self) -> Bool:
        """Return True if the `DatagramStream` handle is gone."""
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the loop was destroyed with this stream in flight."""
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the loop is gone; the handle becomes inert."""
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Record the slot this state lives in and the queue to notify.

        Args:
            link: The slot key and the loop's settle queue.
        """
        self._link = link

    def notify_done(self):
        """Tell the slot link the terminal completion has arrived.

        The stream's own callbacks settle through `_finish`, which also
        clears `_live_counted`; this trait entry point honours that flag
        so a call on a state that already stopped counting only queues
        the slot and cannot decrement the live count a second time.
        """
        if self._live_counted:
            self._link.completed(self._owner_dropped)
        else:
            self._link.dropped(self._owner_dropped)

    def mark_owner_dropped(mut self):
        """Record that the handle let go.

        Queued leases return at once. A disarmed stream, or one whose
        re-arm was still pending, has nothing in flight and settles
        directly; an armed one requests an internal cancel and settles
        when the terminal completion arrives.
        """
        self._owner_dropped = True
        self._return_queued_leases()
        if not self.armed:
            self._finish()
            return
        if self.rearm_requested:
            self.rearm_requested = False
            self.armed = False
            self._finish()
            return
        self.cancel_requested = True
        self._queue_deferred()


# ===----------------------------------------------------------------------=== #
# Datagram — one delivery
# ===----------------------------------------------------------------------=== #


struct Datagram(Movable):
    """One received datagram: a leased buffer plus its decoded delivery header.

    Fields:
        buffer: The lease; dropping the datagram returns it to the pool.
        _flags: The completion flags.
        _control_capacity: Control bytes reserved in the buffer.
    """

    var buffer: LeasedBuffer
    var _flags: UInt32
    var _control_capacity: Int

    def __init__(
        out self,
        var buffer: LeasedBuffer,
        flags: UInt32,
        control_capacity: Int,
    ):
        """Wrap a delivery.

        Args:
            buffer: The lease over the buffer the kernel or loop filled.
            flags: The completion flags.
            control_capacity: Control bytes reserved in the buffer.
        """
        self.buffer = buffer^
        self._flags = flags
        self._control_capacity = control_capacity

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.buffer = move.buffer^
        self._flags = move._flags
        self._control_capacity = move._control_capacity

    def _header(ref self) -> DeliveryHeader[MutUntrackedOrigin]:
        """View the buffer as a delivery; pools guarantee >= 64 bytes.

        An empty view (the lease names no buffer of its pool) decodes as
        zero fields and empty regions rather than reading past its end.
        """
        return DeliveryHeader(
            self.buffer.bytes(), _NAME_CAPACITY, self._control_capacity
        )

    def payload(ref self) -> Span[UInt8, MutUntrackedOrigin]:
        """Return the datagram payload (header, name and control excluded)."""
        return self._header().payload()

    def count(self) -> Int:
        """Return the full length of the datagram as the kernel reported it.

        Equal to `len(payload())` unless the datagram did not fit the
        buffer's payload region: then `truncated()` is True and this is
        the larger, original length. Zero for a lease naming no buffer.
        """
        return Int(self._header().payloadlen())

    def peer_family(self) -> AddrFamily:
        """Return the peer's address family, UNSPEC when no name was written."""
        return AddrFamily.from_sockaddr(self._header().name())

    def peer_v4(self) raises IOError -> SocketAddrV4:
        """Return the IPv4 peer.

        Raises:
            IOError(EAFNOSUPPORT) if the peer is not AF_INET, or if the
            name the kernel wrote is shorter than a `sockaddr_in` (a
            short or absent name is never decoded).
        """
        var name = self._header().name()
        if (
            len(name) < size_of[sockaddr_in]()
            or self.peer_family() != AddrFamily.INET
        ):
            raise IOError(positive_errno=EAFNOSUPPORT)
        var stor = SocketAddrStorV4()
        var dst = Pointer(to=stor.addr).unsafe_bitcast[UInt8]()
        for i in range(size_of[sockaddr_in]()):
            dst[unsafe_offset=i] = name[i]
        return stor.to_v4()

    def peer_v6(self) raises IOError -> SocketAddrV6:
        """Return the IPv6 peer.

        Raises:
            IOError(EAFNOSUPPORT) if the peer is not AF_INET6, or if the
            name the kernel wrote is shorter than a `sockaddr_in6` (a
            short or absent name is never decoded).
        """
        var name = self._header().name()
        if (
            len(name) < size_of[sockaddr_in6]()
            or self.peer_family() != AddrFamily.INET6
        ):
            raise IOError(positive_errno=EAFNOSUPPORT)
        var stor = SocketAddrStorV6()
        var dst = Pointer(to=stor.addr).unsafe_bitcast[UInt8]()
        for i in range(size_of[sockaddr_in6]()):
            dst[unsafe_offset=i] = name[i]
        return stor.to_v6()

    def control(ref self) -> ControlMessages[MutUntrackedOrigin]:
        """Return a walker over the control messages of this datagram."""
        return self._header().control()

    def truncated(self) -> Bool:
        """Return True if the payload did not fit the buffer (MSG_TRUNC)."""
        return (self._header().flags() & UInt32(MSG_TRUNC)) != 0

    def control_truncated(self) -> Bool:
        """Return True if the control records did not fit the control area (MSG_CTRUNC)."""
        return (self._header().flags() & UInt32(MSG_CTRUNC)) != 0


# ===----------------------------------------------------------------------=== #
# DatagramStream — handle returned by WatchLoop.recv_msg_multishot
# ===----------------------------------------------------------------------=== #


struct DatagramStream(Movable):
    """Handle to an armed multishot recvmsg delivering into a `BufferPool`.

    Drive the loop with `step()`; take deliveries with `next()`. When the
    stream ends on an error (`ENOBUFS` once every buffer is leased is the
    expected one) `armed()` turns False and `error()` is set; `rearm()`
    resubmits the operation once the leases are back. Dropping the handle
    cancels the operation and returns queued leases. Once the loop is
    gone the handle is inert.

    A socket that will never yield a datagram again ends the stream on
    epoll only: a read-shut socket reports ECONNRESET, a pending socket
    error is reported as is. On io_uring a read-shut or errored socket
    never terminates the stream; it stays armed with no completion, so
    drop the stream to release it.

    Fields:
        _state: The slab-owned stream state.
    """

    var _state: Pointer[_StreamState, MutUntrackedOrigin]

    def __init__(out self, state: Pointer[_StreamState, MutUntrackedOrigin]):
        """Wrap a slab-owned stream state.

        Args:
            state: Pointer to the `_StreamState`.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._state = move._state

    def __deinit__(deinit self):
        """Hand the stream to the loop, or do nothing if the loop is gone.

        The operation is cancelled at the next `step()` or `run()`, not
        here. On epoll the operation holds a private dup of the socket,
        so the socket's open file stays alive until that tick retires
        the operation even if the caller closed its descriptor: a bind
        to the same port before then gets EADDRINUSE.
        """
        if not self._state[]._loop_gone:
            self._state[].mark_owner_dropped()

    def next(mut self) -> Optional[Datagram]:
        """Pop the oldest delivery, or None when nothing is queued.

        The queue is a plain list popped from the front, so each call
        is linear in the number of queued deliveries; that number is
        bounded by the pool's buffer count.

        Returns:
            The oldest delivery, its buffer leased to the caller.
        """
        if len(self._state[].deliveries) == 0:
            return None
        var d = self._state[].deliveries.pop(0)
        return Optional[Datagram](
            Datagram(
                LeasedBuffer(self._state[].pool, d.buf_id),
                d.flags,
                self._state[].control_capacity,
            )
        )

    def pending(self) -> Int:
        """Return how many deliveries are queued and not yet taken."""
        return len(self._state[].deliveries)

    def armed(self) -> Bool:
        """Return True while the stream expects further deliveries."""
        return self._state[].armed

    def error(self) -> Optional[IOError]:
        """Return the error that ended the stream, if any."""
        return self._state[].error

    def rearm(mut self) raises:
        """Resubmit the operation after the stream ended on an error.

        Legal only when `error()` is set. The socket is not checked:
        ENOBUFS after returning leases is the expected case, and reuse
        of a closed descriptor is the caller's responsibility. The
        submission is deferred to the flush that opens the next
        `step()` or `run()`, whether or not anything is pending.
        Deliveries resume from the following step. The state counts
        live again from this call, so
        `in_flight_count()` includes the stream before the resubmission
        is actually handed to the driver.

        Raises:
            A plain message if the stream is armed (no error to recover
            from) or the loop is gone.
        """
        var st = self._state
        if st[]._loop_gone:
            raise "loop destroyed before completion"
        if not st[].error:
            raise "rearm() is legal only after error() is set"
        st[].error = None
        st[].armed = True
        st[]._live_counted = True
        st[]._link.rearmed()
        st[].rearm_requested = True
        st[]._queue_deferred()
