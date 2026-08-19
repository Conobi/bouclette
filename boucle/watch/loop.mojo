"""WatchLoop — ergonomic completion-based I/O loop."""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.drivers.io_uring import IoUringDriver
from boucle.handle import RawHandle
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.timeout import Timeout
from boucle.watch._callback import _FutureCallback, _trampoline
from boucle.watch.accept import _AcceptFutureState, AcceptFuture
from boucle.watch.connect import _ConnectFutureState, ConnectFuture
from boucle.watch.recv import _RecvFutureState, RecvFuture
from boucle.watch.send import _SendFutureState, SendFuture
from boucle.watch.timer import _TimerFutureState, TimerFuture


comptime _WatchDriver = IoUringDriver


struct WatchLoop(Movable):
    """Opaque event loop for completion-based I/O with Future dispatch.

    The driver is hidden behind a comptime alias. Users never see IoUringDriver.
    """

    var _driver: _WatchDriver
    var _pending: Int

    def __init__(out self, sq_entries: UInt32 = 64) raises:
        """Create a WatchLoop with the given submission queue capacity.

        Args:
            sq_entries: Number of submission queue entries (default 64).
        """
        self._driver = _WatchDriver(sq_entries=sq_entries)
        self._pending = 0

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._driver = move._driver^
        self._pending = move._pending

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
        # 1. Heap-allocate the state.
        var state_ptr = unsafe_alloc[_AcceptFutureState](1)
        var pending_ptr = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._pending))
        )
        state_ptr.unsafe_write(_AcceptFutureState(pending_ptr))

        # 2. Wire completion: trampoline dispatches CQE to typed state.
        state_ptr[].completion.invoke = _trampoline[_AcceptFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        # 3. Get completion pointer for submission.
        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        # 4. Pre-capture fd and submit.
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
        # 1. Heap-allocate the state with a copy of the address storage.
        var state_ptr = unsafe_alloc[_ConnectFutureState](1)
        var pending_ptr = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._pending))
        )
        var addr_stor = SocketAddrStorV4(addr)
        state_ptr.unsafe_write(_ConnectFutureState(addr_stor, pending_ptr))

        # 2. Wire completion: trampoline dispatches CQE to typed state.
        state_ptr[].completion.invoke = _trampoline[_ConnectFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        # 3. Get completion pointer for submission.
        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        # 4. Get addr pointer from the state (stable heap allocation).
        var fd = socket.raw()
        var addr_ptr = state_ptr[]._addr_stor.addr_unsafe_ptr()
        var addr_len = UInt64(SocketAddrStorV4.ADDR_LEN)
        self._driver.submit_connect(fd, addr_ptr, addr_len, cmp_ptr)
        self._pending += 1

        return ConnectFuture(state_ptr)

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
        # 1. Heap-allocate the state.
        var state_ptr = unsafe_alloc[_RecvFutureState](1)
        var pending_ptr = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._pending))
        )
        state_ptr.unsafe_write(_RecvFutureState(pending_ptr))

        # 2. Wire completion.
        state_ptr[].completion.invoke = _trampoline[_RecvFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        # 3. Get completion pointer.
        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        # 4. Submit recv with buffer pointer from caller.
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
        # 1. Heap-allocate the state.
        var state_ptr = unsafe_alloc[_SendFutureState](1)
        var pending_ptr = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._pending))
        )
        state_ptr.unsafe_write(_SendFutureState(pending_ptr))

        # 2. Wire completion.
        state_ptr[].completion.invoke = _trampoline[_SendFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        # 3. Get completion pointer.
        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        # 4. Submit send with buffer pointer from caller.
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
        # 1. Heap-allocate the state with the timeout value.
        var state_ptr = unsafe_alloc[_TimerFutureState](1)
        var pending_ptr = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._pending))
        )
        var ts = Timeout.from_ms(Int64(ms))
        state_ptr.unsafe_write(_TimerFutureState(ts, pending_ptr))

        # 2. Wire completion.
        state_ptr[].completion.invoke = _trampoline[_TimerFutureState]
        state_ptr[].completion.context = state_ptr.unsafe_bitcast[
            NoneType
        ]()

        # 3. Get completion pointer.
        var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=state_ptr[].completion)
            )
        )

        # 4. Get timespec pointer from the state (stable heap allocation).
        var ts_ptr = Pointer[NoneType, ImmStaticOrigin](
            unsafe_from_address=Int(Pointer(to=state_ptr[]._ts))
        )
        self._driver.submit_timeout(ts_ptr, cmp_ptr)
        self._pending += 1

        return TimerFuture(state_ptr)

    def run(mut self) raises:
        """Block until all pending operations complete.

        If run() raises (systemic driver error), the WatchLoop is in an
        undefined state and must not be reused.
        """
        while self._pending > 0:
            self._driver.tick(wait=True)
