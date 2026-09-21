"""`DatagramSink` — fire-and-forget batched datagram sender.

The send-side mirror of `DatagramStream`: pre-allocates N send slots,
each with a stable msghdr/iovec/Completion tuple, and flushes queued
datagrams to the driver with one call per slot. Completions fire in
the background; the user never waits for individual sends.

`_SinkState` is the long-lived slab-owned state; `DatagramSink` is
the handle. `_SendSlot` is one pre-allocated slot in the array.

Two push paths:

- `push(payload, addr, ecn)` copies the payload into a shared buffer
  and stores the peer and optional ECN cmsg per slot. Safe: the
  payload buffer is a `List[UInt8]`.

- `push_msg(msg)` moves a `Message` into the slot's `Optional`. The
  `Message` owns its own payload and control area, and the slot's
  msghdr points at them. Unsafe: the slot array is allocated with
  `unsafe_alloc`.

Completions are tallied as `stream_completions` so the loop does not
count them against `_pending`, and `run()` returns immediately with
only sinks active.
"""

from std.collections import Optional
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.sys.info import size_of

from bouclette.error import IOError
from bouclette.handle import RawHandle
from bouclette.net.addr import (
    SocketAddrStor,
    SocketAddrStorAny,
    SocketAddrStorV6,
)
from bouclette.net.message import Message
from bouclette.net.options import AddrFamily
from bouclette.proactor.completion import Completion
from bouclette.socle.platform import (
    EINVAL,
    EMSGSIZE,
    ENOSPC,
    IP_TOS,
    IPV6_TCLASS,
    SOL_IP,
    SOL_IPV6,
    cmsghdr,
    iovec,
    msghdr,
)
from bouclette.socle.ptr import null_ptr
from bouclette.watch._callback import _InFlightState, _SlotLink
from bouclette.watch._shared import _LoopShared
from bouclette.watch.stream import _is_queue_full


# Slot status values.
comptime _FREE = UInt8(0)
comptime _QUEUED = UInt8(1)
comptime _IN_FLIGHT = UInt8(2)

# Both IP_TOS (1 data byte) and IPV6_TCLASS (4 data bytes) produce a
# 24-byte record after CMSG_ALIGN, so one constant covers both.
comptime _ECN_RECORD_SIZE = 24


# ===----------------------------------------------------------------------=== #
# _SendSlot — one pre-allocated send slot in the sink's array
# ===----------------------------------------------------------------------=== #


struct _SendSlot(Movable):
    """One pre-allocated send slot with stable msghdr and Completion.

    Slots live in a fixed array allocated by `_SinkState` via
    `unsafe_alloc` and never move, so every pointer the driver holds
    (msghdr, iovec, Completion) stays valid for the slot's life.
    """

    var status: UInt8
    var hdr: msghdr
    var iov: iovec
    var peer: SocketAddrStorAny
    var control: List[UInt8]
    var control_appended: Int
    var payload_offset: Int
    var payload_len: Int
    var msg: Optional[Message]
    var completion: Completion
    var state_ptr: Pointer[_SinkState, MutUntrackedOrigin]
    var slot_index: Int

    def __init__(out self, index: Int, control_capacity: Int):
        """Construct a FREE slot with pre-allocated control area.

        Args:
            index: Position in the slot array, stored for free-stack use.
            control_capacity: Bytes reserved for control records per slot.
        """
        self.status = _FREE
        self.hdr = msghdr()
        self.iov = iovec()
        self.peer = SocketAddrStorAny()
        self.control = List[UInt8](length=max(control_capacity, 0), fill=0)
        self.control_appended = 0
        self.payload_offset = 0
        self.payload_len = 0
        self.msg = None
        self.completion = Completion()
        self.state_ptr = null_ptr[_SinkState, MutUntrackedOrigin]()
        self.slot_index = index

    def __init__(out self, *, deinit move: Self):
        self.status = move.status
        self.hdr = move.hdr
        self.iov = move.iov
        self.peer = move.peer
        self.control = move.control^
        self.control_appended = move.control_appended
        self.payload_offset = move.payload_offset
        self.payload_len = move.payload_len
        self.msg = move.msg^
        self.completion = move.completion^
        self.state_ptr = move.state_ptr
        self.slot_index = move.slot_index

    def wire(mut self, payload_buf_addr: Int):
        """Point msghdr and iovec at this slot's fields before submission.

        For `push()` slots, `iov_base` addresses the slot's region in the
        shared payload buffer. For `push_msg()` slots, `iov_base` addresses
        the `Message`'s own payload. Rebuilds the msghdr from scratch on
        every call because the kernel does not modify the send-side msghdr.

        Args:
            payload_buf_addr: Integer address of the shared payload buffer.
        """
        self.hdr = msghdr()
        if self.msg:
            self.iov.iov_base = UInt64(
                Int(self.msg.value()._payload.unsafe_ptr())
            )
            self.iov.iov_len = UInt64(len(self.msg.value()._payload))
        else:
            self.iov.iov_base = UInt64(
                payload_buf_addr + self.payload_offset
            )
            self.iov.iov_len = UInt64(self.payload_len)
        self.hdr.msg_iov = UInt64(Int(Pointer(to=self.iov)))
        self.hdr.msg_iovlen = 1
        # Peer address: from Message for push_msg, from slot for push.
        if self.msg:
            if self.msg.value()._peer.addr_len() > 0:
                self.hdr.msg_name = UInt64(
                    Int(self.msg.value()._peer.addr_unsafe_mut_ptr())
                )
                self.hdr.msg_namelen = UInt32(
                    self.msg.value()._peer.addr_len()
                )
        else:
            if self.peer.addr_len() > 0:
                self.hdr.msg_name = UInt64(
                    Int(self.peer.addr_unsafe_mut_ptr())
                )
                self.hdr.msg_namelen = UInt32(self.peer.addr_len())
        # Control records: from Message for push_msg, from slot for push.
        if self.msg:
            if self.msg.value()._control_appended > 0:
                self.hdr.msg_control = UInt64(
                    Int(self.msg.value()._control.unsafe_ptr())
                )
                self.hdr.msg_controllen = UInt64(
                    self.msg.value()._control_appended
                )
        elif self.control_appended > 0:
            self.hdr.msg_control = UInt64(Int(self.control.unsafe_ptr()))
            self.hdr.msg_controllen = UInt64(self.control_appended)

    def msghdr_ptr(mut self) -> Pointer[NoneType, MutUntrackedOrigin]:
        """Return the opaque msghdr pointer the driver takes."""
        return Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self.hdr))
        )

    def completion_ptr(mut self) -> Pointer[Completion, MutUntrackedOrigin]:
        """Return the Completion pointer the driver stores as user_data."""
        return Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self.completion))
        )

    def reset(mut self):
        """Return the slot to FREE, zeroing the control area.

        The control area is zeroed unconditionally (Go #54693: stale cmsg
        records from a previous send must never be offered to the kernel).
        Any `Message` in the slot is destroyed.
        """
        self.status = _FREE
        self.payload_offset = 0
        self.payload_len = 0
        self.peer = SocketAddrStorAny()
        self.control_appended = 0
        var p = self.control.unsafe_ptr()
        for i in range(len(self.control)):
            p[unsafe_offset=i] = 0
        self.msg = None


# ===----------------------------------------------------------------------=== #
# _SinkState — slab-owned state of one DatagramSink
# ===----------------------------------------------------------------------=== #


struct _SinkState(_InFlightState):
    """Slab-owned state of one `DatagramSink`.

    Owns a fixed array of `_SendSlot` (via `unsafe_alloc`), a shared
    payload buffer for `push()` slots, and a free stack / FIFO queue
    for slot lifecycle. Completions are tallied as `stream_completions`.
    """

    var _slots: Pointer[_SendSlot, MutUntrackedOrigin]
    var _capacity: Int
    var _payload_buf: List[UInt8]
    var _max_payload: Int
    var _control_capacity: Int
    var _free_stack: List[Int]
    var _queue: List[Int]
    var fd: RawHandle
    var _completed: Int
    var _failed: Int
    var _in_flight: Int
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _live_counted: Bool
    var _finished: Bool
    var _link: _SlotLink
    var _shared: Pointer[_LoopShared, MutUntrackedOrigin]

    def __init__(
        out self,
        fd: RawHandle,
        capacity: Int,
        max_payload: Int,
        control_capacity: Int,
        shared: Pointer[_LoopShared, MutUntrackedOrigin],
    ):
        """Allocate the slot array and payload buffer.

        Call `wire_all_completions()` once the state is in its slab slot,
        before any operation is submitted.

        Args:
            fd: The datagram socket.
            capacity: Number of pre-allocated send slots.
            max_payload: Maximum datagram payload per slot, in bytes.
            control_capacity: Bytes reserved for control records per slot.
            shared: The loop's shared box.
        """
        self._slots = unsafe_alloc[_SendSlot](capacity)
        self._capacity = capacity
        self._payload_buf = List[UInt8](
            length=capacity * max_payload, fill=0
        )
        self._max_payload = max_payload
        self._control_capacity = control_capacity
        self._free_stack = List[Int](capacity=capacity)
        self._queue = List[Int](capacity=capacity)
        self.fd = fd
        self._completed = 0
        self._failed = 0
        self._in_flight = 0
        self._owner_dropped = False
        self._loop_gone = False
        self._live_counted = True
        self._finished = False
        self._link = _SlotLink()
        self._shared = shared
        # Initialize slots in reverse so the free stack pops low indices
        # first, matching the slab's convention.
        var i = capacity - 1
        while i >= 0:
            self._slots.unsafe_offset(i).unsafe_write(
                _SendSlot(i, control_capacity)
            )
            self._free_stack.append(i)
            i -= 1

    def __init__(out self, *, deinit move: Self):
        self._slots = move._slots
        self._capacity = move._capacity
        self._payload_buf = move._payload_buf^
        self._max_payload = move._max_payload
        self._control_capacity = move._control_capacity
        self._free_stack = move._free_stack^
        self._queue = move._queue^
        self.fd = move.fd
        self._completed = move._completed
        self._failed = move._failed
        self._in_flight = move._in_flight
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._live_counted = move._live_counted
        self._finished = move._finished
        self._link = move._link
        self._shared = move._shared

    def __deinit__(deinit self):
        """Destroy every slot and free the slot array."""
        for i in range(self._capacity):
            self._slots.unsafe_offset(i).unsafe_deinit_pointee()
        self._slots.unsafe_free()

    def wire_all_completions(mut self):
        """Wire every slot's Completion and back-pointer after slab placement.

        Must run once, after the `_SinkState` is in its slab slot and
        before any operation is submitted. The addresses recorded are
        those of the fixed slot array and this state, which never move.
        """
        var state_addr = Pointer[_SinkState, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self))
        )
        for i in range(self._capacity):
            var slot = self._slots.unsafe_offset(i)
            var ctx = Pointer[NoneType, MutUntrackedOrigin](
                unsafe_from_address=Int(slot)
            )
            slot[].completion = Completion(Self._on_send_done, ctx)
            slot[].state_ptr = state_addr

    def push_into_slot(
        mut self,
        payload: Span[UInt8, _],
        peer: SocketAddrStorAny,
        ecn: UInt8,
    ) raises IOError:
        """Copy payload into the shared buffer and queue the slot.

        Args:
            payload: Datagram body, at most `_max_payload` bytes.
            peer: Destination address.
            ecn: ECN codepoint (0-3); 0 means no ECN cmsg.

        Raises:
            `IOError(ENOSPC)` when no free slot is available.
            `IOError(EMSGSIZE)` when the payload exceeds `max_payload`.
            `IOError(EINVAL)` when the loop is gone, the address family
            is unrecognised, or the control capacity cannot hold an ECN
            record.
        """
        if self._loop_gone:
            raise IOError(positive_errno=EINVAL)
        if len(self._free_stack) == 0:
            raise IOError(positive_errno=ENOSPC)
        if len(payload) > self._max_payload:
            raise IOError(positive_errno=EMSGSIZE)
        var idx = self._free_stack.pop()
        var slot = self._slots.unsafe_offset(idx)
        debug_assert(slot[].status == _FREE, "free-stack slot not FREE")
        # Copy payload into the slot's fixed region.
        slot[].payload_offset = idx * self._max_payload
        slot[].payload_len = len(payload)
        var dst = self._payload_buf.unsafe_ptr().unsafe_offset(
            slot[].payload_offset
        )
        for i in range(len(payload)):
            dst[unsafe_offset=i] = payload[i]
        slot[].peer = peer
        # Append ECN cmsg when requested.
        if ecn > 0:
            var fam = peer.family()
            if fam == AddrFamily.INET6:
                var stor = SocketAddrStorV6()
                stor.addr = peer.addr
                if stor.to_v6().is_ipv4_mapped():
                    fam = AddrFamily.INET
            if fam != AddrFamily.INET and fam != AddrFamily.INET6:
                self._return_slot(idx)
                raise IOError(positive_errno=EINVAL)
            if self._control_capacity < _ECN_RECORD_SIZE:
                self._return_slot(idx)
                raise IOError(positive_errno=EINVAL)
            var hdr_size = size_of[cmsghdr]()
            var p = slot[].control.unsafe_ptr()
            if fam == AddrFamily.INET:
                p.unsafe_bitcast[UInt64]().unsafe_store[alignment=1](
                    UInt64(hdr_size + 1)
                )
                p.unsafe_offset(8).unsafe_bitcast[Int32]().unsafe_store[
                    alignment=1
                ](Int32(SOL_IP))
                p.unsafe_offset(12).unsafe_bitcast[Int32]().unsafe_store[
                    alignment=1
                ](Int32(IP_TOS))
                p[unsafe_offset=hdr_size] = ecn & 0x03
                for i in range(hdr_size + 1, _ECN_RECORD_SIZE):
                    p[unsafe_offset=i] = 0
            else:
                p.unsafe_bitcast[UInt64]().unsafe_store[alignment=1](
                    UInt64(hdr_size + 4)
                )
                p.unsafe_offset(8).unsafe_bitcast[Int32]().unsafe_store[
                    alignment=1
                ](Int32(SOL_IPV6))
                p.unsafe_offset(12).unsafe_bitcast[Int32]().unsafe_store[
                    alignment=1
                ](Int32(IPV6_TCLASS))
                p[unsafe_offset=hdr_size] = ecn & 0x03
                p[unsafe_offset=hdr_size + 1] = 0
                p[unsafe_offset=hdr_size + 2] = 0
                p[unsafe_offset=hdr_size + 3] = 0
                for i in range(hdr_size + 4, _ECN_RECORD_SIZE):
                    p[unsafe_offset=i] = 0
            slot[].control_appended = _ECN_RECORD_SIZE
        slot[].status = _QUEUED
        self._queue.append(idx)

    def push_msg_into_slot(mut self, var msg: Message) raises IOError:
        """Move a `Message` into a free slot and queue it.

        The `Message` owns its payload and control area; the slot's
        msghdr will point at them when wired at flush time.

        Args:
            msg: The message, moved in for the duration of the send.

        Raises:
            `IOError(ENOSPC)` when no free slot is available.
            `IOError(EINVAL)` when the loop is gone.
        """
        if self._loop_gone:
            raise IOError(positive_errno=EINVAL)
        if len(self._free_stack) == 0:
            raise IOError(positive_errno=ENOSPC)
        var idx = self._free_stack.pop()
        var slot = self._slots.unsafe_offset(idx)
        debug_assert(slot[].status == _FREE, "free-stack slot not FREE")
        slot[].msg = msg^
        slot[].status = _QUEUED
        self._queue.append(idx)

    def flush_via_sendmsg(mut self) raises IOError -> Int:
        """Submit queued slots to the driver via `sendmsg`.

        Each queued slot is wired and submitted. A slot refused because
        the submission queue is full stays QUEUED and is retried on the
        next flush. Any other driver error resets the slot and counts it
        as failed. Returns 0 when the driver is gone.

        Returns:
            Number of slots successfully submitted.
        """
        if self._loop_gone or not self._shared[].driver_alive:
            raise IOError(positive_errno=EINVAL)
        var submitted = 0
        var remaining = List[Int]()
        var payload_addr = Int(self._payload_buf.unsafe_ptr())
        for i in range(len(self._queue)):
            var idx = self._queue[i]
            var slot = self._slots.unsafe_offset(idx)
            slot[].wire(payload_addr)
            try:
                self._shared[].driver[].sendmsg(
                    self.fd,
                    slot[].msghdr_ptr(),
                    slot[].completion_ptr(),
                )
                slot[].status = _IN_FLIGHT
                self._in_flight += 1
                submitted += 1
            except e:
                if _is_queue_full(e):
                    remaining.append(idx)
                else:
                    self._return_slot(idx)
                    self._failed += 1
        self._queue = remaining^
        return submitted

    def _return_slot(mut self, idx: Int):
        """Reset a slot and return it to the free stack (error-path helper).

        Args:
            idx: Index of the slot to return.
        """
        self._slots.unsafe_offset(idx)[].reset()
        self._free_stack.append(idx)

    def _finish(mut self):
        """Owner dropped and all in-flight sends completed: settle the slot.

        Idempotent: the `_finished` flag prevents double-settle. Any
        slots still in the queue (pushed but never flushed) are returned
        before the slab slot is settled.
        """
        if self._finished:
            return
        self._finished = True
        for i in range(len(self._queue)):
            self._return_slot(self._queue[i])
        self._queue.clear()
        if self._live_counted:
            self._live_counted = False
            self._link.completed(True)
        else:
            self._link.dropped(True)

    @staticmethod
    def _on_send_done(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Completion callback for a submitted `sendmsg`.

        Resets the slot, returns it to the free stack, and updates
        counters. Tallied as `stream_completions` so the loop does not
        subtract it from `_pending`. Settles the slab slot when the
        owner has dropped and every in-flight send has completed.

        Args:
            ctx: Pointer to the `_SendSlot` that completed.
            result: Bytes sent (>= 0) or negative errno.
            flags: Completion flags (unused for sendmsg).
        """
        var slot = ctx.unsafe_bitcast[_SendSlot]()
        var state = slot[].state_ptr
        state[]._shared[].stream_completions += 1
        var idx = slot[].slot_index
        slot[].reset()
        state[]._free_stack.append(idx)
        if result >= 0:
            state[]._completed += 1
        else:
            state[]._failed += 1
        state[]._in_flight -= 1
        if state[]._owner_dropped and state[]._in_flight == 0:
            state[]._finish()

    # ── _InFlightState ───────────────────────────────────────────────────

    def is_done(self) -> Bool:
        """Return True when no completion can write this state again."""
        return self._in_flight == 0

    def owner_dropped(self) -> Bool:
        """Return True if the `DatagramSink` handle is gone."""
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the loop was destroyed with this sink alive."""
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the loop is gone; the handle becomes inert."""
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Record the slot this state lives in and the queue to notify."""
        self._link = link

    def notify_done(self):
        """No-op: the per-slot callback settles the slab slot directly."""
        pass

    def mark_owner_dropped(mut self):
        """Record that the handle let go and finish if nothing is in flight.

        Queued-but-never-flushed slots are returned to the free stack
        immediately, since no future flush will submit them.
        """
        self._owner_dropped = True
        for i in range(len(self._queue)):
            self._return_slot(self._queue[i])
        self._queue.clear()
        if self._in_flight == 0:
            self._finish()

    def abandon_buffer(mut self):
        """Give up memory the kernel may still be reading.

        In-flight `push_msg()` slots have their `Message` parked on the
        heap (leaked). In-flight `push()` slots reference the shared
        payload buffer, which is parked on the heap if any such slot
        exists; those with a non-empty control area (`control_appended
        > 0`) also have their per-slot `control` list parked, since the
        msghdr's `msg_control` points at it. Called at loop destruction
        before the driver is torn down.
        """
        var leak_payload = False
        for i in range(self._capacity):
            var slot = self._slots.unsafe_offset(i)
            if slot[].status == _IN_FLIGHT:
                if slot[].msg:
                    var m = slot[].msg.take()
                    var parked = unsafe_alloc[Message](1)
                    parked.unsafe_write(m^)
                else:
                    leak_payload = True
                    if slot[].control_appended > 0:
                        var ctl_ptr = Pointer[
                            List[UInt8], MutUntrackedOrigin
                        ](
                            unsafe_from_address=Int(
                                Pointer(to=slot[].control)
                            )
                        )
                        var ctl = ctl_ptr.unsafe_take_pointee()
                        ctl_ptr.unsafe_write(List[UInt8]())
                        var parked_ctl = unsafe_alloc[List[UInt8]](1)
                        parked_ctl.unsafe_write(ctl^)
        if leak_payload:
            var parked = unsafe_alloc[List[UInt8]](1)
            parked.unsafe_write(self._payload_buf^)
            self._payload_buf = List[UInt8]()


# ===----------------------------------------------------------------------=== #
# DatagramSink — handle returned by WatchLoop.datagram_sink
# ===----------------------------------------------------------------------=== #


struct DatagramSink(Movable):
    """Fire-and-forget batched datagram sender.

    Queue datagrams with `push()` or `push_msg()`, submit them with
    `flush()`, and drive the loop with `step()`. Completions happen
    in the background; `completed()` and `failed()` report totals.
    Dropping the handle releases queued-but-unflushed slots immediately;
    in-flight sends complete in the background and the slab slot
    settles once the last one finishes.
    """

    var _state: Pointer[_SinkState, MutUntrackedOrigin]

    def __init__(
        out self, state: Pointer[_SinkState, MutUntrackedOrigin]
    ):
        """Wrap a slab-owned sink state.

        Args:
            state: Pointer to the `_SinkState` in its slab slot.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        self._state = move._state

    def __deinit__(deinit self):
        """Hand the sink to the loop, or do nothing if the loop is gone."""
        if not self._state[]._loop_gone:
            self._state[].mark_owner_dropped()

    def push[
        Addr: SocketAddrStor
    ](
        mut self,
        payload: Span[UInt8, _],
        ref addr: Addr,
        ecn: UInt8 = 0,
    ) raises IOError:
        """Queue a datagram for the next `flush()`.

        The payload is copied into a shared buffer; the original is not
        referenced after this call returns.

        Parameters:
            Addr: The address type, SocketAddrV4 or SocketAddrV6.

        Args:
            payload: Datagram body, at most `max_payload` bytes.
            addr: Destination address.
            ecn: ECN codepoint (0-3); 0 sends without an ECN cmsg.

        Raises:
            `IOError(ENOSPC)` if every slot is in use.
            `IOError(EMSGSIZE)` if the payload exceeds `max_payload`.
            `IOError(EINVAL)` if the address family is unrecognised
            or the control capacity cannot hold an ECN record.
        """
        self._state[].push_into_slot(
            payload, SocketAddrStorAny(addr.addr_stor()), ecn
        )

    def push_msg(mut self, var msg: Message) raises IOError:
        """Queue a pre-built `Message` for the next `flush()`.

        The `Message` is moved into the sink; the caller cannot access
        it afterwards. Peer, payload and control records are taken from
        the `Message` as configured.

        Args:
            msg: The message, moved into a send slot.

        Raises:
            `IOError(ENOSPC)` if every slot is in use.
        """
        self._state[].push_msg_into_slot(msg^)

    def flush(mut self) raises IOError -> Int:
        """Submit queued datagrams to the driver.

        Each queued slot is submitted as one `sendmsg`. A slot refused
        because the submission queue is full stays queued and is retried
        on the next flush. Any other driver error resets the slot and
        counts it as failed. Returns 0 when no slots are queued or the
        loop is gone.

        Returns:
            Number of datagrams successfully submitted.
        """
        return self._state[].flush_via_sendmsg()

    def pending(self) -> Int:
        """Return how many datagrams are queued but not yet submitted."""
        return len(self._state[]._queue)

    def in_flight(self) -> Int:
        """Return how many datagrams are submitted and awaiting completion."""
        return self._state[]._in_flight

    def completed(self) -> Int:
        """Return how many sends completed successfully (cumulative)."""
        return self._state[]._completed

    def failed(self) -> Int:
        """Return how many sends failed (cumulative)."""
        return self._state[]._failed
