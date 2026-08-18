"""Readiness-based I/O — get notified when I/O is possible, then do it yourself.

Best for:
  - Multiplexed connections (HTTP/2, HTTP/3, QUIC)
  - Frequent cancellation (timeouts, request racing)
  - Fine-grained scheduling (stream prioritization)

You retain buffer ownership at all times. Cancel by simply
stopping to poll.

See `boucle.completion` for the alternative model.
"""

from boucle.drivers import _ReadinessDriver
from boucle.handle import RawHandle
from boucle.interest import Interest
from boucle.readiness_state import Readiness
from boucle.token import Token
from std.memory import Pointer


trait ReadinessHandler(Movable, Deinitable):
    """Callback interface for readiness events.

    The handler receives an unsafe pointer to the owning loop so it
    can self-deregister, modify interest, or rearm in oneshot mode.

    Safety contract: the pointer is valid only for the duration of the
    `on_ready` call. Do not store it. Do not pass it to other threads.
    The loop owns the handler, so passing `mut loop: ReadinessLoop[Self]`
    would alias with `mut self` — hence the pointer indirection.
    """

    def on_ready(
        mut self,
        loop: Pointer[ReadinessLoop[Self], MutUntrackedOrigin],
        token: Token,
        readiness: Readiness,
    ):
        ...


struct ReadinessLoop[Handler: ReadinessHandler](Movable):
    """Opaque readiness event loop. Backend resolved at comptime.

    Register file descriptors with interest flags, then poll to
    discover which ones are ready for I/O. You perform the actual
    I/O yourself after being notified.

    The underlying driver (epoll, kqueue, ...) is selected via the
    comptime `_ReadinessDriver` alias in `boucle.drivers`.
    """

    var _driver: _ReadinessDriver
    var _handler: Self.Handler

    def __init__(
        out self, var handler: Self.Handler, *, max_events: Int32 = 64
    ) raises:
        """Create a readiness loop with the given handler.

        Args:
            handler: Callback object invoked for each readiness event.
            max_events: Maximum events returned per poll() call
                        (default 64).
        """
        self._driver = _ReadinessDriver(max_events=max_events)
        self._handler = handler^

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._driver = move._driver^
        self._handler = move._handler^

    def register(mut self, fd: RawHandle, interest: Interest, token: Token) raises:
        """Add a file descriptor to the interest set.

        Args:
            fd: The file descriptor to monitor.
            interest: Which I/O events to watch for.
            token: Opaque token returned on notification.
        """
        self._driver.register(fd, interest, token)

    def modify(mut self, fd: RawHandle, interest: Interest, token: Token) raises:
        """Modify the interest flags for a registered file descriptor.

        Args:
            fd: The registered file descriptor.
            interest: New set of I/O events to watch for.
            token: New opaque token for subsequent notifications.
        """
        self._driver.modify(fd, interest, token)

    def deregister(mut self, fd: RawHandle) raises:
        """Remove a file descriptor from the interest set.

        Args:
            fd: The registered file descriptor to remove.
        """
        self._driver.deregister(fd)

    def poll(mut self, *, timeout_ms: Int32 = -1) raises:
        """Wait for readiness events and invoke handler for each.

        Calls the driver's poll(), then dispatches each returned
        ReadinessEvent to the handler's on_ready callback.

        Args:
            timeout_ms: Maximum milliseconds to wait (-1 = infinite,
                        0 = non-blocking).
        """
        var events = self._driver.poll(timeout_ms=timeout_ms)
        for i in range(len(events)):
            # Construct a loop pointer with an unconstrained origin so it
            # doesn't alias with the `mut self._handler` borrow below.
            # Safety: the pointer is valid only for the duration of the
            # on_ready call; the loop outlives the handler invocation.
            var loop_ptr = Pointer[Self, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=self))
            )
            self._handler.on_ready(
                loop_ptr,
                events[i].token,
                events[i].readiness,
            )
