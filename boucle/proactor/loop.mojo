"""EventLoop — single-threaded event loop driven by completions."""

from boucle.drivers.driver import IoDriver


struct EventLoop[D: IoDriver](Movable):
    """Single-threaded event loop wrapping an IoDriver.

    Three ways to drive it, named as everywhere else in boucle:
    `run_once()` is one blocking tick, `poll()` one non-blocking tick,
    and `run_forever()` repeats blocking ticks until `stop()`.

    `run_once()` takes no timeout: the driver's tick() only offers
    "wait" or "do not wait", so a bounded wait would have to be faked
    with a timer operation the caller can submit just as well.

    Not generic over a handler — operations bring their own Completion
    callbacks.
    """

    var driver: Self.D
    var running: Bool

    def __init__(out self, var driver: Self.D):
        """Construct an EventLoop wrapping the given driver.

        Args:
            driver: The IoDriver backend (consumed).
        """
        self.driver = driver^
        self.running = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.driver = move.driver^
        self.running = move.running

    def __deinit__(deinit self):
        """Destroy the event loop and its underlying driver."""
        self.driver^.__deinit__()

    def run_once(mut self) raises:
        """Run one blocking tick.

        Waits for at least one completion, then dispatches every
        completion that is ready by the time it wakes up.
        """
        _ = self.driver.tick(wait=True)

    def poll(mut self) raises:
        """Run one non-blocking tick.

        Dispatches the completions that are already available and
        returns, even when there are none.
        """
        _ = self.driver.tick(wait=False)

    def run_forever(mut self) raises:
        """Run blocking ticks until stop() is called."""
        self.running = True
        while self.running:
            self.run_once()

    def stop(mut self):
        """Signal the loop to exit after the current tick."""
        self.running = False
