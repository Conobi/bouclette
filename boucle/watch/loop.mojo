"""WatchLoop — ergonomic completion-based I/O loop."""

from boucle.drivers.io_uring import IoUringDriver


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

    def run(mut self) raises:
        """Block until all pending operations complete.

        If run() raises (systemic driver error), the WatchLoop is in an
        undefined state and must not be reused.
        """
        while self._pending > 0:
            self._driver.tick(wait=True)
