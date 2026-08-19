"""WatchLoop — ergonomic completion-based I/O loop."""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.drivers.io_uring import IoUringDriver
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.watch._callback import _FutureCallback, _trampoline
from boucle.watch.accept import _AcceptFutureState, AcceptFuture


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

    def run(mut self) raises:
        """Block until all pending operations complete.

        If run() raises (systemic driver error), the WatchLoop is in an
        undefined state and must not be reused.
        """
        while self._pending > 0:
            self._driver.tick(wait=True)
