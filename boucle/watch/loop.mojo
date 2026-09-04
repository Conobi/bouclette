"""WatchLoop — ergonomic completion-based I/O loop.

Every operation method heap-allocates a per-operation state whose
Completion address is handed to the driver, and returns a Future handle
owning that state. The loop records every such state in an in-flight
registry and owns it jointly with the handle (rules in `_callback.mojo`):

- run() sweeps the registry after each tick: states that are done leave
  it, and those whose handle was already dropped are freed there.
- Destroying the loop while operations are in flight tears the driver
  down first, then settles every remaining entry: orphaned states are
  freed, states still owned by a live handle are marked `loop_gone` so
  the handle frees them on drop and result() reports the loss.

No state is ever freed by a completion callback, and nothing leaks if
run() is never called again after a drop.

recv() and send() take their buffer by value and move it into that same
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
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.timeout import Timeout
from boucle.watch._callback import _FutureCallback, _InFlightEntry, _dispatch
from boucle.watch.accept import _AcceptFutureState, AcceptFuture
from boucle.watch.connect import _ConnectFutureState, ConnectFuture
from boucle.watch.connect_timeout import (
    _ConnectWithTimeoutState,
    ConnectWithTimeoutFuture,
)
from boucle.watch.recv import _RecvFutureState, RecvFuture
from boucle.watch.send import _SendFutureState, SendFuture
from boucle.watch.timer import _TimerFutureState, TimerFuture


struct WatchLoop(Movable):
    """Opaque event loop for completion-based I/O with Future dispatch.

    The driver is hidden behind a comptime alias. Users never see IoUringDriver.
    _pending tracks completions in flight — each operation adds 1, each
    dispatched completion subtracts 1, managed entirely by run().

    _in_flight is the registry of every operation state not yet settled,
    simple and composite alike; it is what lets the loop free orphaned
    states and inform surviving handles when the loop is destroyed.

    _composites_awaiting_cancel additionally lists the composite states,
    because only they need the loop to submit a deferred cancel
    operation after each tick. It never owns anything: a composite is dropped
    from it as soon as it is done, and the registry alone decides who
    frees the state.
    """

    var _driver: _WatchDriver
    var _pending: Int
    var _in_flight: List[_InFlightEntry]
    var _composites_awaiting_cancel: List[
        Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin]
    ]

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
        self._in_flight = List[_InFlightEntry]()
        self._composites_awaiting_cancel = List[
            Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin]
        ]()

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._driver = move._driver^
        self._pending = move._pending
        self._in_flight = move._in_flight^
        self._composites_awaiting_cancel = move._composites_awaiting_cancel^

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

        Every remaining registry entry is then detached: orphaned states
        are freed here, states still owned by a live handle are marked
        `loop_gone`. Freeing a state is safe at that point because its
        buffer has already been abandoned, so nothing the kernel may
        still touch goes back to the allocator.
        """
        for entry in self._in_flight:
            entry.abandon(entry.state)
        self._driver^.__deinit__()
        for entry in self._in_flight:
            entry.detach(entry.state)
        self._in_flight.clear()
        self._composites_awaiting_cancel.clear()

    def backend(self) -> Backend:
        """Return which kernel I/O mechanism is active."""
        return self._driver.backend()

    def in_flight_count(self) -> Int:
        """Return how many operation states the loop still tracks.

        Diagnostic accessor for tests: every submitted operation is
        registered until run() has seen it complete, so this must be 0
        after run() returns. A composite counts as one entry.

        Returns:
            The number of registry entries not yet settled.
        """
        return len(self._in_flight)

    def pending_composites(self) -> Int:
        """Return how many connect_with_timeout operations still await a cancel.

        Diagnostic accessor for tests: a composite stays listed from
        submission until run() has seen all three of its completions,
        so this must be 0 after run() returns.

        Returns:
            The number of composite operations awaiting completion.
        """
        return len(self._composites_awaiting_cancel)

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
        var state_ptr = unsafe_alloc[_AcceptFutureState](1)
        state_ptr.unsafe_write(_AcceptFutureState())

        state_ptr[].completion.invoke = _dispatch[_AcceptFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        var fd = socket.raw()
        self._driver.accept(fd, cmp_ptr)
        self._pending += 1
        self._in_flight.append(_InFlightEntry(state_ptr))

        return AcceptFuture(state_ptr)

    def connect(
        mut self, ref socket: Socket, ref addr: SocketAddrV4
    ) raises -> ConnectFuture:
        """Submit an async connect on a socket to the given address.

        Returns a ConnectFuture that resolves to a ConnectOutcome after
        run() completes. The address storage is copied into the
        heap-allocated state for pointer stability.

        Args:
            socket: The socket to connect.
            addr: The target IPv4 address to connect to.

        Returns:
            A ConnectFuture representing the in-flight connect.
        """
        var state_ptr = unsafe_alloc[_ConnectFutureState](1)
        var addr_stor = SocketAddrStorV4(addr)
        state_ptr.unsafe_write(_ConnectFutureState(addr_stor))

        state_ptr[].completion.invoke = _dispatch[_ConnectFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        var fd = socket.raw()
        var addr_ptr = state_ptr[]._addr_stor.addr_unsafe_ptr()
        var addr_len = UInt64(SocketAddrStorV4.ADDR_LEN)
        self._driver.connect(fd, addr_ptr, addr_len, cmp_ptr)
        self._pending += 1
        self._in_flight.append(_InFlightEntry(state_ptr))

        return ConnectFuture(state_ptr)

    def connect_with_timeout(
        mut self,
        ref socket: Socket,
        ref addr: SocketAddrV4,
        timeout_ms: UInt64,
    ) raises -> ConnectWithTimeoutFuture:
        """Submit a connect with a kernel-level timeout.

        Submits both a connect operation and a timeout operation. The
        first to complete resolves the operation; the other is cancelled.
        Returns a ConnectWithTimeoutFuture that resolves to a
        ConnectOutcome after run() completes.

        Args:
            socket: The socket to connect.
            addr: The target IPv4 address.
            timeout_ms: Timeout in milliseconds.

        Returns:
            A ConnectWithTimeoutFuture representing the in-flight
            composite operation.
        """
        var state_ptr = unsafe_alloc[_ConnectWithTimeoutState](1)
        var addr_stor = SocketAddrStorV4(addr)
        var ts = Timeout.from_ms(Int64(timeout_ms))
        state_ptr.unsafe_write(
            _ConnectWithTimeoutState(addr_stor, ts)
        )

        state_ptr[]._connect_cmp.invoke = (
            _ConnectWithTimeoutState._on_connect_cb
        )
        state_ptr[]._connect_cmp.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        state_ptr[]._timeout_cmp.invoke = (
            _ConnectWithTimeoutState._on_timeout_cb
        )
        state_ptr[]._timeout_cmp.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        state_ptr[]._cancel_cmp.invoke = (
            _ConnectWithTimeoutState._on_cancel_cb
        )
        state_ptr[]._cancel_cmp.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        var fd = socket.raw()
        var connect_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[]._connect_cmp)
            )
        )
        var addr_ptr = state_ptr[]._addr_stor.addr_unsafe_ptr()
        var addr_len = UInt64(SocketAddrStorV4.ADDR_LEN)
        self._driver.connect(fd, addr_ptr, addr_len, connect_cmp_ptr)

        var timeout_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[]._timeout_cmp)
            )
        )
        var ts_ptr = Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[]._ts))
        )
        self._driver.timeout(ts_ptr, timeout_cmp_ptr)

        # 2 operations submitted → 2 completions expected.
        self._pending += 2
        self._in_flight.append(_InFlightEntry(state_ptr))
        self._composites_awaiting_cancel.append(state_ptr)

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
        var state_ptr = unsafe_alloc[_RecvFutureState](1)
        state_ptr.unsafe_write(_RecvFutureState(buf^))

        state_ptr[].completion.invoke = _dispatch[_RecvFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        var fd = socket.raw()
        var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(state_ptr[].buf.unsafe_ptr())
        )
        var buf_len = UInt32(len(state_ptr[].buf))
        self._driver.recv(fd, buf_ptr, buf_len, cmp_ptr)
        self._pending += 1
        self._in_flight.append(_InFlightEntry(state_ptr))

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
        var state_ptr = unsafe_alloc[_SendFutureState](1)
        state_ptr.unsafe_write(_SendFutureState(buf^))

        state_ptr[].completion.invoke = _dispatch[_SendFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        var fd = socket.raw()
        var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(state_ptr[].buf.unsafe_ptr())
        )
        var buf_len = UInt32(len(state_ptr[].buf))
        self._driver.send(fd, buf_ptr, buf_len, cmp_ptr)
        self._pending += 1
        self._in_flight.append(_InFlightEntry(state_ptr))

        return SendFuture(state_ptr)

    def timeout(mut self, timeout_ms: UInt64) raises -> TimerFuture:
        """Submit an async timeout (kernel timer).

        Returns a TimerFuture that resolves to True (expired) or False
        (cancelled) after run() completes.

        Args:
            timeout_ms: How long to wait, in milliseconds.

        Returns:
            A TimerFuture representing the in-flight timeout.
        """
        var state_ptr = unsafe_alloc[_TimerFutureState](1)
        var ts = Timeout.from_ms(Int64(timeout_ms))
        state_ptr.unsafe_write(_TimerFutureState(ts))

        state_ptr[].completion.invoke = _dispatch[_TimerFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        var ts_ptr = Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[]._ts))
        )
        self._driver.timeout(ts_ptr, cmp_ptr)
        self._pending += 1
        self._in_flight.append(_InFlightEntry(state_ptr))

        return TimerFuture(state_ptr)

    def run(mut self) raises:
        """Block until every submitted operation has completed, then return.

        This is the "drain" verb, and the only way to drive a WatchLoop:
        there is nothing to run forever on a loop whose work is a set of
        futures. `CompletionLoop` is where `run_forever()`, `run_once()`
        and `poll()` live.

        _pending tracks completions in flight. tick() returns the number
        of dispatched completions; run() decrements directly. Callbacks
        never touch the counter — they only set result state.

        After each tick, first flushes deferred cancel operations for
        composite operations (each cancel adds 1 to _pending for its own
        completion) and forgets the composites whose three completions
        have all arrived, then sweeps the in-flight registry: every
        state that is done leaves
        it, and the ones whose handle was dropped early are freed there.
        The cancel list is trimmed before the sweep so it never keeps a
        pointer to a state the sweep is about to free.

        If run() raises (systemic driver error), the WatchLoop is in an
        undefined state and must not be reused.
        """
        while self._pending > 0:
            var dispatched = self._driver.tick(wait=True)
            self._pending -= dispatched
            self._flush_composite_cancels()
            self._sweep_in_flight()

    def _flush_composite_cancels(mut self) raises:
        """Submit deferred cancel operations and forget finished composites.

        Called after each tick, before the registry sweep. Only
        composites need this step; the registry handles their ownership.
        """
        var i = len(self._composites_awaiting_cancel) - 1
        while i >= 0:
            var state_ptr = self._composites_awaiting_cancel[i]
            self._pending += state_ptr[].flush_cancel(self._driver)
            if state_ptr[].done:
                _ = self._composites_awaiting_cancel.pop(i)
            i -= 1

    def _sweep_in_flight(mut self):
        """Drop every settled registry entry, freeing the orphaned ones.

        Called after each tick. Each entry's sweep hook reports whether
        the state is done and, if its handle was already dropped, frees
        it; done entries leave the registry either way.
        """
        var i = len(self._in_flight) - 1
        while i >= 0:
            var entry = self._in_flight[i].copy()
            if entry.sweep(entry.state):
                _ = self._in_flight.pop(i)
            i -= 1
