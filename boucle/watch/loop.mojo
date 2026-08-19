"""WatchLoop — ergonomic completion-based I/O loop."""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.drivers.io_uring import IoUringDriver
from boucle.handle import RawHandle
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.timeout import Timeout
from boucle.watch._callback import _FutureCallback, _dispatch
from boucle.watch.accept import _AcceptFutureState, AcceptFuture
from boucle.watch.connect import _ConnectFutureState, ConnectFuture
from boucle.watch.connect_timeout import (
    _ConnectWithTimeoutState,
    ConnectWithTimeoutFuture,
)
from boucle.watch.recv import _RecvFutureState, RecvFuture
from boucle.watch.send import _SendFutureState, SendFuture
from boucle.watch.timer import _TimerFutureState, TimerFuture


comptime _WatchDriver = IoUringDriver


struct WatchLoop(Movable):
    """Opaque event loop for completion-based I/O with Future dispatch.

    The driver is hidden behind a comptime alias. Users never see IoUringDriver.
    _pending tracks CQEs in flight — each SQE adds 1, each dispatched CQE
    subtracts 1, managed entirely by run().
    """

    var _driver: _WatchDriver
    var _pending: Int
    var _active_composites: List[
        Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin]
    ]

    def __init__(out self, sq_entries: UInt32 = 64) raises:
        """Create a WatchLoop with the given submission queue capacity.

        Args:
            sq_entries: Number of submission queue entries (default 64).
        """
        self._driver = _WatchDriver(sq_entries=sq_entries)
        self._pending = 0
        self._active_composites = List[
            Pointer[_ConnectWithTimeoutState, MutUntrackedOrigin]
        ]()

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._driver = move._driver^
        self._pending = move._pending
        self._active_composites = move._active_composites^

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
        self._driver.submit_accept(fd, cmp_ptr)
        self._pending += 1

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
        self._driver.submit_connect(fd, addr_ptr, addr_len, cmp_ptr)
        self._pending += 1

        return ConnectFuture(state_ptr)

    def connect_with_timeout(
        mut self,
        ref socket: Socket,
        ref addr: SocketAddrV4,
        timeout_ms: UInt64,
    ) raises -> ConnectWithTimeoutFuture:
        """Submit a connect with a kernel-level timeout.

        Submits both a connect SQE and a timeout SQE. The first to
        complete resolves the operation; the other is cancelled.
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
        self._driver.submit_connect(fd, addr_ptr, addr_len, connect_cmp_ptr)

        var timeout_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[]._timeout_cmp)
            )
        )
        var ts_ptr = Pointer[NoneType, ImmStaticOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[]._ts))
        )
        self._driver.submit_timeout(ts_ptr, timeout_cmp_ptr)

        # 2 SQEs submitted → 2 CQEs expected.
        self._pending += 2
        self._active_composites.append(state_ptr)

        return ConnectWithTimeoutFuture(state_ptr)

    def recv(
        mut self,
        ref socket: Socket,
        buf: Span[UInt8, MutAnyOrigin],
    ) raises -> RecvFuture:
        """Submit an async recv on a socket into the given buffer.

        Returns a RecvFuture that resolves to the number of bytes read
        after run() completes.

        Warning: The buffer is NOT owned by the future. The caller must
        ensure the buffer remains valid until run() completes.

        Args:
            socket: The socket to receive from.
            buf: Mutable buffer to receive into. Must outlive run().

        Returns:
            A RecvFuture representing the in-flight recv.
        """
        var state_ptr = unsafe_alloc[_RecvFutureState](1)
        state_ptr.unsafe_write(_RecvFutureState())

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
            unsafe_from_address=Int(buf.unsafe_ptr())
        )
        self._driver.submit_recv(fd, buf_ptr, UInt32(len(buf)), cmp_ptr)
        self._pending += 1

        return RecvFuture(state_ptr)

    def send[
        origin: Origin
    ](
        mut self,
        ref socket: Socket,
        buf: Span[UInt8, origin],
    ) raises -> SendFuture:
        """Submit an async send on a socket from the given buffer.

        Returns a SendFuture that resolves to the number of bytes
        written after run() completes.

        Warning: The buffer is NOT owned by the future. The caller must
        ensure the buffer remains valid until run() completes.

        Args:
            socket: The socket to send on.
            buf: Data to send. Must outlive run().

        Returns:
            A SendFuture representing the in-flight send.
        """
        var state_ptr = unsafe_alloc[_SendFutureState](1)
        state_ptr.unsafe_write(_SendFutureState())

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
            unsafe_from_address=Int(buf.unsafe_ptr())
        )
        self._driver.submit_send(fd, buf_ptr, UInt32(len(buf)), cmp_ptr)
        self._pending += 1

        return SendFuture(state_ptr)

    def timeout(mut self, ms: UInt64) raises -> TimerFuture:
        """Submit an async timeout (kernel timer).

        Returns a TimerFuture that resolves to True (expired) or False
        (cancelled) after run() completes.

        Args:
            ms: Timeout in milliseconds.

        Returns:
            A TimerFuture representing the in-flight timeout.
        """
        var state_ptr = unsafe_alloc[_TimerFutureState](1)
        var ts = Timeout.from_ms(Int64(ms))
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

        var ts_ptr = Pointer[NoneType, ImmStaticOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[]._ts))
        )
        self._driver.submit_timeout(ts_ptr, cmp_ptr)
        self._pending += 1

        return TimerFuture(state_ptr)

    def run(mut self) raises:
        """Block until all pending CQEs have been dispatched.

        _pending tracks CQEs in flight. tick() returns the number of
        dispatched CQEs; run() decrements directly. Callbacks never
        touch the counter — they only set result state.

        After each tick, flushes deferred cancel SQEs for composite
        operations (each cancel adds 1 to _pending for its own CQE).

        If run() raises (systemic driver error), the WatchLoop is in an
        undefined state and must not be reused.
        """
        while self._pending > 0:
            var dispatched = self._driver.tick(wait=True)
            self._pending -= dispatched
            var i = len(self._active_composites) - 1
            while i >= 0:
                var state_ptr = self._active_composites[i]
                var cancels = state_ptr[].flush_cancel(self._driver)
                self._pending += cancels
                if state_ptr[].done:
                    _ = self._active_composites.pop(i)
                i -= 1
