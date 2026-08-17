"""EventLoop — single-threaded event loop driven by completions."""

from boucle.drivers.driver import IoDriver


struct EventLoop[D: IoDriver](Movable):
    """Single-threaded event loop wrapping an IoDriver.

    Provides blocking and non-blocking poll methods. Not generic over
    a handler — operations bring their own Completion callbacks.
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

    def __init__(out self, *, deinit take: Self):
        """Move constructor."""
        self.driver = take.driver^
        self.running = take.running

    def __del__(deinit self):
        """Destroy the event loop and its underlying driver."""
        self.driver^.__del__()

    def run_once(mut self) raises:
        """Block until at least one completion fires, then dispatch all ready."""
        self.driver.tick(wait=True)

    def try_poll(mut self) raises:
        """Non-blocking: dispatch any ready completions, return immediately."""
        self.driver.tick(wait=False)

    def run(mut self) raises:
        """Run until stop() is called."""
        self.running = True
        while self.running:
            self.run_once()

    def stop(mut self):
        """Signal the loop to exit after the current tick."""
        self.running = False
