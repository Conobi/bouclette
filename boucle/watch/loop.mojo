"""WatchLoop — ergonomic completion-based I/O loop.

Every operation method places a per-operation state in a loop-owned
slab (one per state type, `_slab.mojo`), hands the state's Completion
address to the driver, and returns a Future handle pointing at that
slot. Slab chunks never move, so the address stays valid for the life
of the loop, and submitting an operation costs a free-list pop rather
than a heap allocation. The slab is also the registry (rules in
`_callback.mojo`):

- Each state carries the key of its slot. Of the completion arriving
  and the handle letting go, whichever happens second pushes that key
  onto the loop's settle queue, so run() releases exactly the slots
  that became reclaimable since the last tick and visits nothing else.
- Destroying the loop while operations are in flight tears the driver
  down first, then settles every remaining slot: orphaned states are
  released, states still owned by a live handle are marked `loop_gone`
  so result() reports the loss, and the chunks holding them stay
  allocated for as long as the handle may read them.

No state is ever freed by a completion callback or by a handle, and
nothing leaks if run() is never called again after a drop.

recv() and send() take their buffer by value, and recv_msg() and
send_msg() take their Message by value, and move it into that same
per-operation state, so the loop owns the bytes the kernel touches for
exactly as long as the operation lives. The caller gets the buffer back
from result(); until then it cannot read it, write it or free it, and
dropping the future simply gives it up.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.drivers import _WatchDriver
from boucle.drivers.backend import Backend
from boucle.handle import RawHandle
from boucle.net.addr import SocketAddrStor, SocketAddrStorAny
from boucle.net.message import Message
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.timeout import Timeout
from boucle.watch._callback import _KIND_BITS, _FutureCallback, _dispatch
from boucle.watch._message import _MessageState
from boucle.watch._slab import _Slab
from boucle.watch.accept import _AcceptFutureState, AcceptFuture
from boucle.watch.connect import _ConnectFutureState, ConnectFuture
from boucle.watch.connect_timeout import (
    _ConnectWithTimeoutState,
    ConnectWithTimeoutFuture,
)
from boucle.watch.recv import _RecvFutureState, RecvFuture
from boucle.watch.recv_msg import RecvMsgFuture
from boucle.watch.send import _SendFutureState, SendFuture
from boucle.watch.send_msg import SendMsgFuture
from boucle.watch.timer import _TimerFutureState, TimerFuture


# Slab kinds, stored in the low `_KIND_BITS` of every settle-queue key.
comptime _KIND_ACCEPT = 0
comptime _KIND_CONNECT = 1
comptime _KIND_CONNECT_WITH_TIMEOUT = 2
comptime _KIND_RECV = 3
comptime _KIND_SEND = 4
comptime _KIND_TIMER = 5
comptime _KIND_RECV_MSG = 6
comptime _KIND_SEND_MSG = 7


struct WatchLoop(Movable):
    """Opaque event loop for completion-based I/O with Future dispatch.

    The driver is hidden behind a comptime alias. Users never see IoUringDriver.
    _pending tracks completions in flight — each operation adds 1, each
    dispatched completion subtracts 1; both run() and step() drive that
    bookkeeping.

    The eight slabs hold every operation state, simple and composite
    alike, and double as the registry of what is not yet settled; they
    are what let the loop release orphaned states and inform surviving
    handles when the loop is destroyed. _settle is the queue of slot
    keys pushed by completions and handle drops since the last sweep;
    it lives on the heap so its address survives moving the loop.

    _deferred lists the slot keys of states that may still need the loop
    to submit an operation on their behalf outside a callback: today the
    composites, from submission until their three completions have
    arrived, because the loser's cancel is submitted after the tick that
    resolved them. It never owns anything: a key is dropped from it as
    soon as the state is done, and the registry alone decides who frees
    the state.
    """

    var _driver: _WatchDriver
    var _pending: Int
    var _settle: Pointer[List[Int], MutUntrackedOrigin]
    var _settling: List[Int]
    var _accepts: _Slab[_AcceptFutureState]
    var _connects: _Slab[_ConnectFutureState]
    var _connects_with_timeout: _Slab[_ConnectWithTimeoutState]
    var _recvs: _Slab[_RecvFutureState]
    var _sends: _Slab[_SendFutureState]
    var _timers: _Slab[_TimerFutureState]
    var _recv_msgs: _Slab[_MessageState]
    var _send_msgs: _Slab[_MessageState]
    var _deferred: List[Int]

    def __init__(
        out self, *, capacity: Int = 64, backend: Backend = Backend.AUTO
    ) raises:
        """Create a WatchLoop with the given capacity hint.

        Args:
            capacity: How many operations the loop should be ready to
                      hold at once (default 64). A hint — the backend
                      may round it up, and exceeding it is not an error.
            backend: Which kernel mechanism to drive the loop with.
                     AUTO probes for the native completion backend and
                     falls back to the readiness one.
        """
        self._driver = _WatchDriver(capacity=capacity, backend=backend)
        self._pending = 0
        self._settle = unsafe_alloc[List[Int]](1)
        self._settle.unsafe_write(List[Int](capacity=capacity))
        self._settling = List[Int](capacity=capacity)
        var q = self._settle
        self._accepts = _Slab[_AcceptFutureState](capacity, _KIND_ACCEPT, q)
        self._connects = _Slab[_ConnectFutureState](capacity, _KIND_CONNECT, q)
        self._connects_with_timeout = _Slab[_ConnectWithTimeoutState](
            capacity, _KIND_CONNECT_WITH_TIMEOUT, q
        )
        self._recvs = _Slab[_RecvFutureState](capacity, _KIND_RECV, q)
        self._sends = _Slab[_SendFutureState](capacity, _KIND_SEND, q)
        self._timers = _Slab[_TimerFutureState](capacity, _KIND_TIMER, q)
        self._recv_msgs = _Slab[_MessageState](capacity, _KIND_RECV_MSG, q)
        self._send_msgs = _Slab[_MessageState](capacity, _KIND_SEND_MSG, q)
        self._deferred = List[Int]()

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._driver = move._driver^
        self._pending = move._pending
        self._settle = move._settle
        self._settling = move._settling^
        self._accepts = move._accepts^
        self._connects = move._connects^
        self._connects_with_timeout = move._connects_with_timeout^
        self._recvs = move._recvs^
        self._sends = move._sends^
        self._timers = move._timers^
        self._recv_msgs = move._recv_msgs^
        self._send_msgs = move._send_msgs^
        self._deferred = move._deferred^

    def __deinit__(deinit self):
        """Abandon in-flight buffers, tear the driver down, settle the registry.

        The first pass asks every unfinished operation to give up the
        memory the kernel may still be reading or writing. Closing the
        submission handle asks the kernel to cancel those requests, but
        cancellation is not instantaneous and nothing here waits for it,
        so an abandoned recv/send buffer is leaked on purpose instead of
        being returned to the allocator — see `abandon_buffer` in
        `_callback.mojo`. Waiting instead is not an option: a loop
        destroyed with a ten-second timer armed must not block for ten
        seconds.

        The driver goes second so that no completion callback can run
        while the registry is being settled. Once it is gone nothing
        references the Completion inside any state anymore:

        - Completion backend: operations are only pushed to the kernel
          from tick(), so operations never run through run() were never
          submitted at all; for the ones that were, closing the
          submission handle cancels them kernel-side and their
          completions land in a queue nobody reads. The kernel copies
          the timespec and sockaddr at submission, so freeing `_ts` /
          `_addr_stor` is safe too.
        - Readiness backend: destroying the driver closes the poll
          descriptor and frees its op pool and timer heap, so no
          callback can fire either.

        Every remaining slot is then detached: orphaned states are
        released here, states still owned by a live handle are marked
        `loop_gone` and their slab keeps its chunks allocated for that
        handle. Releasing a state is safe at that point because its
        buffer has already been abandoned, so nothing the kernel may
        still touch goes back to the allocator.

        Message operations need one more precaution. A recvmsg writes
        the peer address, `msg_namelen`, `msg_controllen` and
        `msg_flags` back into the msghdr and name slot at completion,
        and for a `_MessageState` those live in the slab chunk itself,
        not in the parked message. Closing the ring does not wait for
        that write-back, so if any message operation is still unfinished
        here its slab is marked leaked before anything else happens: the
        chunks then stay allocated for as long as the kernel might still
        write into them, the same bargain `detach_all` makes for a held
        handle. Slabs with no unfinished message operation are freed as
        usual.

        The `in_flight() > 0` check above is deliberately conservative.
        It also leaks the slab when a message op was allocated but never
        reached the kernel (submission failed after `alloc`), and on the
        epoll completion backend, whose recvmsg runs synchronously inside
        `tick()` rather than asynchronously in the kernel — neither case
        actually needs the safeguard. That is acceptable — a few extra
        chunks kept alive at process exit are cheaper than teaching this
        destructor which in-flight state came from which path.
        """
        if self._recv_msgs.in_flight() > 0:
            self._recv_msgs._leaked = True
        if self._send_msgs.in_flight() > 0:
            self._send_msgs._leaked = True
        self._accepts.abandon_all()
        self._connects.abandon_all()
        self._connects_with_timeout.abandon_all()
        self._recvs.abandon_all()
        self._sends.abandon_all()
        self._timers.abandon_all()
        self._recv_msgs.abandon_all()
        self._send_msgs.abandon_all()
        self._driver^.__deinit__()
        self._accepts.detach_all()
        self._connects.detach_all()
        self._connects_with_timeout.detach_all()
        self._recvs.detach_all()
        self._sends.detach_all()
        self._timers.detach_all()
        self._recv_msgs.detach_all()
        self._send_msgs.detach_all()
        self._deferred.clear()
        self._settle.unsafe_deinit_pointee()
        self._settle.unsafe_free()

    def backend(self) -> Backend:
        """Return which kernel I/O mechanism is active."""
        return self._driver.backend()

    def in_flight_count(self) -> Int:
        """Return how many operation states the loop still tracks.

        Diagnostic accessor for tests: every submitted operation is
        registered until run() has seen it complete, so this must be 0
        after run() returns. A composite counts as one entry.

        Returns:
            The number of slab slots whose operation is not yet done.
        """
        return (
            self._accepts.in_flight()
            + self._connects.in_flight()
            + self._connects_with_timeout.in_flight()
            + self._recvs.in_flight()
            + self._sends.in_flight()
            + self._timers.in_flight()
            + self._recv_msgs.in_flight()
            + self._send_msgs.in_flight()
        )

    def pending_composites(self) -> Int:
        """Return how many states still hold a deferred submission slot.

        Diagnostic accessor for tests: a composite stays listed from
        submission until run() or step() has seen all three of its
        completions, so this must be 0 once the loop is drained.

        Returns:
            The number of states on the deferred list.
        """
        return len(self._deferred)

    def accept(mut self, ref socket: Socket) raises -> AcceptFuture:
        """Submit an async accept on a listening socket.

        Returns an AcceptFuture that resolves to the accepted Socket
        after run() completes. The future owns the result — call
        future.result() to extract the Socket.

        Args:
            socket: The listening socket to accept on.

        Returns:
            An AcceptFuture representing the in-flight accept.
        """
        var state_ptr = self._accepts.alloc(_AcceptFutureState())

        state_ptr[].completion.invoke = _dispatch[_AcceptFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[NoneType]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[].completion))
        )

        var fd = socket.raw()
        self._driver.accept(fd, cmp_ptr)
        self._pending += 1

        return AcceptFuture(state_ptr)

    def connect[
        Addr: SocketAddrStor
    ](mut self, ref socket: Socket, ref addr: Addr) raises -> ConnectFuture:
        """Submit an async connect on a socket to the given address.

        Returns a ConnectFuture that resolves to a ConnectOutcome after
        run() completes. The address is converted to its kernel storage
        and copied into the slab-owned state for pointer stability.

        Parameters:
            Addr: The address type, SocketAddrV4 or SocketAddrV6.

        Args:
            socket: The socket to connect; its family must match `addr`.
            addr: The target IPv4 or IPv6 address to connect to.

        Returns:
            A ConnectFuture representing the in-flight connect.
        """
        var stor = addr.addr_stor()
        var state_ptr = self._connects.alloc(
            _ConnectFutureState(SocketAddrStorAny(stor))
        )

        state_ptr[].completion.invoke = _dispatch[_ConnectFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[NoneType]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[].completion))
        )

        var fd = socket.raw()
        var addr_ptr = state_ptr[]._addr_stor.addr_unsafe_ptr()
        var addr_len = UInt64(state_ptr[]._addr_stor.addr_len())
        self._driver.connect(fd, addr_ptr, addr_len, cmp_ptr)
        self._pending += 1

        return ConnectFuture(state_ptr)

    def connect_with_timeout[
        Addr: SocketAddrStor
    ](
        mut self,
        ref socket: Socket,
        ref addr: Addr,
        timeout_ms: UInt64,
    ) raises -> ConnectWithTimeoutFuture:
        """Submit a connect with a kernel-level timeout.

        Submits both a connect operation and a timeout operation. The
        first to complete resolves the operation; the other is cancelled.
        Returns a ConnectWithTimeoutFuture that resolves to a
        ConnectOutcome after run() completes. The address is converted
        to its kernel storage and copied into the slab-owned state for
        pointer stability.

        Parameters:
            Addr: The address type, SocketAddrV4 or SocketAddrV6.

        Args:
            socket: The socket to connect; its family must match `addr`.
            addr: The target IPv4 or IPv6 address.
            timeout_ms: Timeout in milliseconds.

        Returns:
            A ConnectWithTimeoutFuture representing the in-flight
            composite operation.
        """
        var stor = addr.addr_stor()
        var ts = Timeout.from_ms(Int64(timeout_ms))
        var state_ptr = self._connects_with_timeout.alloc(
            _ConnectWithTimeoutState(SocketAddrStorAny(stor), ts)
        )

        state_ptr[]._connect_cmp.invoke = (
            _ConnectWithTimeoutState._on_connect_cb
        )
        state_ptr[]._connect_cmp.context = state_ptr.unsafe_bitcast[NoneType]()

        state_ptr[]._timeout_cmp.invoke = (
            _ConnectWithTimeoutState._on_timeout_cb
        )
        state_ptr[]._timeout_cmp.context = state_ptr.unsafe_bitcast[NoneType]()

        state_ptr[]._cancel_cmp.invoke = _ConnectWithTimeoutState._on_cancel_cb
        state_ptr[]._cancel_cmp.context = state_ptr.unsafe_bitcast[NoneType]()

        var fd = socket.raw()
        var connect_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[]._connect_cmp))
        )
        var addr_ptr = state_ptr[]._addr_stor.addr_unsafe_ptr()
        var addr_len = UInt64(state_ptr[]._addr_stor.addr_len())
        self._driver.connect(fd, addr_ptr, addr_len, connect_cmp_ptr)

        var timeout_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[]._timeout_cmp))
        )
        var ts_ptr = Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[]._ts))
        )
        self._driver.timeout(ts_ptr, timeout_cmp_ptr)

        # 2 operations submitted → 2 completions expected.
        self._pending += 2
        self._deferred.append(state_ptr[]._link.key)

        return ConnectWithTimeoutFuture(state_ptr)

    def recv(
        mut self, ref socket: Socket, var buf: List[UInt8]
    ) raises -> RecvFuture:
        """Submit an async recv on a socket into the given buffer.

        The buffer moves into the loop for the duration of the
        operation, so the caller cannot read it, write it or free it
        while the kernel writes into it. `RecvFuture.result()` hands it
        back together with the number of bytes received; dropping the
        future instead gives the buffer up, and the loop frees it once
        the completion has arrived.

        The buffer's current length is the readable window: a list of
        length 32 asks for at most 32 bytes, whatever its capacity.
        Receiving does not change the length — the byte count from
        result() says how many bytes at the front are valid.

        Args:
            socket: The socket to receive from.
            buf: The buffer to receive into, moved into the operation.

        Returns:
            A RecvFuture owning both the operation and the buffer.

        Raises:
            If the socket handle is invalid or the driver cannot accept
            the operation.
        """
        var state_ptr = self._recvs.alloc(_RecvFutureState(buf^))

        state_ptr[].completion.invoke = _dispatch[_RecvFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[NoneType]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[].completion))
        )

        var fd = socket.raw()
        var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(state_ptr[].buf.unsafe_ptr())
        )
        var buf_len = UInt32(len(state_ptr[].buf))
        self._driver.recv(fd, buf_ptr, buf_len, cmp_ptr)
        self._pending += 1

        return RecvFuture(state_ptr)

    def send(
        mut self, ref socket: Socket, var buf: List[UInt8]
    ) raises -> SendFuture:
        """Submit an async send on a socket from the given buffer.

        The buffer moves into the loop for the duration of the
        operation, so nobody can modify or free the bytes while the
        kernel reads them. `SendFuture.result()` hands the buffer back
        unchanged together with the number of bytes written; dropping
        the future instead gives the buffer up, and the loop frees it
        once the completion has arrived.

        The buffer's whole length is offered to the kernel. A short send
        is not an error: compare the byte count from result() with the
        length submitted.

        Args:
            socket: The socket to send on.
            buf: The data to send, moved into the operation.

        Returns:
            A SendFuture owning both the operation and the buffer.

        Raises:
            If the socket handle is invalid or the driver cannot accept
            the operation.
        """
        var state_ptr = self._sends.alloc(_SendFutureState(buf^))

        state_ptr[].completion.invoke = _dispatch[_SendFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[NoneType]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[].completion))
        )

        var fd = socket.raw()
        var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(state_ptr[].buf.unsafe_ptr())
        )
        var buf_len = UInt32(len(state_ptr[].buf))
        self._driver.send(fd, buf_ptr, buf_len, cmp_ptr)
        self._pending += 1

        return SendFuture(state_ptr)

    def recv_msg(
        mut self, ref socket: Socket, var msg: Message
    ) raises -> RecvMsgFuture:
        """Submit an async recvmsg on a socket into the given message.

        The message moves into the loop for the duration of the
        operation. Its payload's length is the receive window; its peer
        slot receives the sender's address; up to `control_capacity`
        bytes of control records are collected (a receiver that wants
        ECN calls `Socket.set_recv_tos` and passes `control_capacity`
        of at least 24). `RecvMsgFuture.result()` hands the message back
        with the byte count, the peer and the flags; dropping the future
        gives it up.

        On a datagram socket one call receives one datagram; bytes past
        the window are dropped and `truncated()` reports it.

        Dropping the future does not remove the operation from `run()`'s
        pending total: the completion still counts, so `run()` blocks
        until a datagram arrives for it. Use `step(timeout_ms)` instead
        when that is not wanted.

        Args:
            socket: The socket to receive from.
            msg: The message to receive into, moved into the operation.

        Returns:
            A RecvMsgFuture owning both the operation and the message.

        Raises:
            If the socket handle is invalid or the driver cannot accept
            the operation.
        """
        var state_ptr = self._recv_msgs.alloc(
            _MessageState(msg^, receiving=True)
        )
        state_ptr[].wire()

        state_ptr[].completion.invoke = _dispatch[_MessageState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[NoneType]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[].completion))
        )

        var fd = socket.raw()
        self._driver.recvmsg(fd, state_ptr[].msghdr_ptr(), cmp_ptr)
        self._pending += 1

        return RecvMsgFuture(state_ptr)

    def send_msg(
        mut self, ref socket: Socket, var msg: Message
    ) raises -> SendMsgFuture:
        """Submit an async sendmsg on a socket from the given message.

        The message moves into the loop for the duration of the
        operation. Its whole payload is offered; a peer set with
        `Message.set_peer` is the destination (required on an
        unconnected datagram socket); control records appended with
        `Message.set_ecn` go out with it. `SendMsgFuture.result()` hands
        the message back unchanged with the byte count; dropping the
        future gives it up.

        Args:
            socket: The socket to send on.
            msg: The message to send, moved into the operation.

        Returns:
            A SendMsgFuture owning both the operation and the message.

        Raises:
            If the socket handle is invalid or the driver cannot accept
            the operation.
        """
        var state_ptr = self._send_msgs.alloc(
            _MessageState(msg^, receiving=False)
        )
        state_ptr[].wire()

        state_ptr[].completion.invoke = _dispatch[_MessageState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[NoneType]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[].completion))
        )

        var fd = socket.raw()
        self._driver.sendmsg(fd, state_ptr[].msghdr_ptr(), cmp_ptr)
        self._pending += 1

        return SendMsgFuture(state_ptr)

    def send_to[
        Addr: SocketAddrStor
    ](
        mut self, ref socket: Socket, var buf: List[UInt8], ref addr: Addr
    ) raises -> SendMsgFuture:
        """Submit an async send of `buf` to `addr` on an unconnected datagram socket.

        A wrapper over `send_msg`: the buffer becomes a `Message` with
        `addr` as its peer and no control records. The result is a
        `SendMsgFuture`; `result().take_message().take_payload()` gives
        the buffer back.

        Parameters:
            Addr: The address type, SocketAddrV4 or SocketAddrV6.

        Args:
            socket: The socket to send on; its family must match `addr`.
            buf: The datagram, moved into the operation.
            addr: The destination.

        Returns:
            A SendMsgFuture owning both the operation and the buffer.

        Raises:
            If the socket handle is invalid or the driver cannot accept
            the operation.
        """
        var msg = Message(buf^)
        msg.set_peer(addr)
        return self.send_msg(socket, msg^)

    def recv_from(
        mut self, ref socket: Socket, var buf: List[UInt8]
    ) raises -> RecvMsgFuture:
        """Submit an async receive of one datagram and its sender into `buf`.

        A wrapper over `recv_msg` with no control area: the buffer's
        length is the window, and the result's `peer_v4()`/`peer_v6()`
        decode the sender.

        Dropping the future does not remove the operation from `run()`'s
        pending total: the completion still counts, so `run()` blocks
        until a datagram arrives for it. Use `step(timeout_ms)` instead
        when that is not wanted.

        Args:
            socket: The socket to receive from.
            buf: The window, moved into the operation.

        Returns:
            A RecvMsgFuture owning both the operation and the buffer.

        Raises:
            If the socket handle is invalid or the driver cannot accept
            the operation.
        """
        return self.recv_msg(socket, Message(buf^))

    def timeout(mut self, timeout_ms: UInt64) raises -> TimerFuture:
        """Submit an async timeout (kernel timer).

        Returns a TimerFuture that resolves to True (expired) or False
        (cancelled) after run() completes.

        Args:
            timeout_ms: How long to wait, in milliseconds.

        Returns:
            A TimerFuture representing the in-flight timeout.
        """
        var ts = Timeout.from_ms(Int64(timeout_ms))
        var state_ptr = self._timers.alloc(_TimerFutureState(ts))

        state_ptr[].completion.invoke = _dispatch[_TimerFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[NoneType]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[].completion))
        )

        var ts_ptr = Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[]._ts))
        )
        self._driver.timeout(ts_ptr, cmp_ptr)
        self._pending += 1

        return TimerFuture(state_ptr)

    def step(mut self, timeout_ms: Int = -1) raises -> Int:
        """Drive the loop for one tick, waiting at most `timeout_ms`.

        This is the verb for long-lived work: `run()` returns as soon as
        no one-shot operation is pending, so a program whose only work
        re-arms itself (a datagram stream) calls `step()` in its own
        loop and decides when to stop.

        One call does, in order:

        1. Flush deferred submissions (re-arms, internal cancels) queued
           since the last flush.
        2. Wait until at least one completion is available or
           `timeout_ms` has passed. -1 waits without limit; 0 polls.
        3. Dispatch every completion available at that moment.
        4. Flush deferred submissions again, then sweep settled slots.
        5. Return the number of completions dispatched in 3 that belong
           to a handle the caller can observe.

        A re-arm queued in step 4 is submitted in step 1 of the next
        call. The loop's own bookkeeping completions — the cancel a
        `connect_with_timeout` submits for its loser — are dispatched
        but not counted; a driver's sentinel timeout is skipped by the
        driver before dispatch, so it never reaches step() at all. A
        composite's losing completion (the cancelled timer's ECANCELED)
        counts as observable too, so `connect_with_timeout` contributes
        two to the returned total while its handle resolves once.

        Args:
            timeout_ms: Upper bound on the wait, in milliseconds. -1
                        waits until a completion arrives; 0 returns
                        after dispatching what is already available.

        Returns:
            The number of observable completions dispatched, 0 when the
            bound expired first.
        """
        var internal_pre = self._flush_deferred()
        debug_assert(
            internal_pre == 0,
            "pre-tick flush must not observe internal completions",
        )
        var dispatched = self._driver.tick(wait=True, timeout_ms=timeout_ms)
        self._pending -= dispatched
        var internal = self._flush_deferred()
        self._sweep_in_flight()
        return dispatched - internal

    def run(mut self) raises:
        """Block until every one-shot operation has completed, then return.

        This is the "drain" verb: submit futures, call run(), read
        results. It counts one-shot operations only; an operation that
        re-arms itself is not pending, so with nothing but such work
        armed run() returns immediately — drive those with `step()`.
        `CompletionLoop` is where `run_forever()`, `run_once()` and
        `poll()` live.

        _pending tracks completions in flight. tick() returns the number
        of dispatched completions; run() decrements directly. Callbacks
        never touch the counter — they only set result state.

        After each tick, first flushes the deferred list (a composite's
        cancel adds 1 to _pending for its own completion; composites
        whose three completions have all arrived are forgotten), then
        settles the slots whose key was queued during the tick: the
        ones whose handle was dropped early are released there. The
        deferred list is trimmed before the sweep so it never names a
        slot the sweep is about to free.

        If run() raises (systemic driver error), the WatchLoop is in an
        undefined state and must not be reused.
        """
        while self._pending > 0:
            var dispatched = self._driver.tick(wait=True)
            self._pending -= dispatched
            _ = self._flush_deferred()
            self._sweep_in_flight()

    def _flush_deferred(mut self) raises -> Int:
        """Submit deferred operations, drop finished states, count internal completions.

        Called before and after each `step()` tick, and after each
        `run()` tick. Every listed key is decoded
        to its slab and slot; the state submits whatever it deferred
        (today: a composite's cancel), reports the internal completions
        it has seen since the previous flush, and is dropped from the
        list once done. The list is walked from the back so a pop does
        not disturb the indices still to visit.

        Returns:
            The number of completions dispatched since the previous
            flush that belong to the loop's own bookkeeping and must not
            be reported by `step()`.
        """
        var internal = 0
        var i = len(self._deferred) - 1
        while i >= 0:
            var key = self._deferred[i]
            var kind = key & ((1 << _KIND_BITS) - 1)
            var index = key >> _KIND_BITS
            debug_assert(
                kind == _KIND_CONNECT_WITH_TIMEOUT,
                "only composites defer submissions today",
            )
            var state_ptr = self._connects_with_timeout._slot(index)
            internal += state_ptr[].take_internal_completions()
            self._pending += state_ptr[].flush_cancel(self._driver)
            if state_ptr[].done:
                _ = self._deferred.pop(i)
            i -= 1
        return internal

    def _sweep_in_flight(mut self):
        """Settle every slot queued since the last sweep.

        Called after each tick. The queue holds the key of every slot
        whose completion has arrived and whose handle has let go since
        the last sweep; each key is routed to its slab, which releases
        the slot. The queue is swapped with a spare list before it is
        walked, so nothing can push to the list being iterated and no
        list is allocated per tick.
        """
        swap(self._settling, self._settle[])
        for key in self._settling:
            var kind = key & ((1 << _KIND_BITS) - 1)
            var index = key >> _KIND_BITS
            if kind == _KIND_RECV:
                self._recvs.settle(index)
            elif kind == _KIND_SEND:
                self._sends.settle(index)
            elif kind == _KIND_TIMER:
                self._timers.settle(index)
            elif kind == _KIND_RECV_MSG:
                self._recv_msgs.settle(index)
            elif kind == _KIND_SEND_MSG:
                self._send_msgs.settle(index)
            elif kind == _KIND_ACCEPT:
                self._accepts.settle(index)
            elif kind == _KIND_CONNECT:
                self._connects.settle(index)
            else:
                self._connects_with_timeout.settle(index)
        self._settling.clear()
