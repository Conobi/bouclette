"""Readiness-based I/O — get notified when I/O is possible, then do it yourself.

Best for:
  - Multiplexed connections (HTTP/2, HTTP/3, QUIC)
  - Frequent cancellation (timeouts, request racing)
  - Fine-grained scheduling (stream prioritization)

You retain buffer ownership at all times. Cancel by simply
stopping to poll.

The loop is split in two: `ReadinessRegistry` owns the interest set,
`ReadinessLoop` owns the registry plus the handler and drives the
dispatch. A handler receives the registry — never the loop — so it can
deregister itself or change its interest with ordinary, checked calls.

See `boucle.watch` (`WatchLoop`) for the completion model.
"""

from boucle.drivers import _ReadinessDriver
from boucle.drivers.backend import Backend
from boucle.drivers.readiness_event import ReadinessEvent
from boucle.handle import RawHandle
from boucle.interest import Interest
from boucle.net.socket import Socket
from boucle.readiness_state import Readiness
from boucle.token import Token
from std.collections import Optional


comptime _MAX_WAIT_MS = UInt64(Int32.MAX)
"""Longest bounded wait a platform driver accepts, in milliseconds."""


@always_inline
def _driver_timeout(timeout_ms: Optional[UInt64]) -> Int32:
    """Convert a public timeout into the driver's signed milliseconds.

    Args:
        timeout_ms: Milliseconds to wait, or None for "wait forever".

    Returns:
        -1 for None, otherwise the value clamped to what the driver's
        millisecond field can hold (~24 days).
    """
    if not timeout_ms:
        return Int32(-1)
    var ms = timeout_ms.value()
    return Int32(ms if ms < _MAX_WAIT_MS else _MAX_WAIT_MS)


struct ReadinessRegistry(Movable):
    """The interest set of a readiness loop.

    Owns the platform driver (epoll, kqueue, ...) and is the only way to
    add, change, or remove registrations. `ReadinessLoop` holds one and
    lends it to the handler for the duration of each `on_ready` call, so
    a handler can act on the interest set without ever holding a
    reference to the loop that owns it.

    The `Socket` methods are the portable ones. The `_raw` variants take
    a bare file descriptor, for pipes, timerfds, and other non-socket
    resources.
    """

    var _driver: _ReadinessDriver

    def __init__(out self, *, capacity: Int = 64) raises:
        """Create a registry with its own platform driver.

        Args:
            capacity: How many events one wait may report (default 64).
                      A hint: events beyond it are simply reported by
                      the next wait.
        """
        self._driver = _ReadinessDriver(capacity=capacity)

    def __init__(out self, *, deinit move: Self):
        self._driver = move._driver^

    def register(
        mut self, ref socket: Socket, interest: Interest, token: Token
    ) raises:
        """Add a socket to the interest set.

        Args:
            socket: The socket to monitor. Must outlive the registration.
            interest: Which I/O events to watch for.
            token: Opaque token returned on notification.

        Raises:
            If the socket is closed, or already registered.
        """
        self._driver.register(socket.raw(), interest, token)

    def register_raw(
        mut self, fd: RawHandle, interest: Interest, token: Token
    ) raises:
        """Add a bare file descriptor to the interest set.

        Args:
            fd: The file descriptor to monitor. Must stay open for as
                long as it is registered.
            interest: Which I/O events to watch for.
            token: Opaque token returned on notification.

        Raises:
            If the descriptor is invalid, or already registered.
        """
        self._driver.register(fd, interest, token)

    def modify(
        mut self, ref socket: Socket, interest: Interest, token: Token
    ) raises:
        """Replace the interest flags and token of a registered socket.

        Args:
            socket: The registered socket.
            interest: New set of I/O events to watch for.
            token: New opaque token for subsequent notifications.

        Raises:
            If the socket is closed, or not registered.
        """
        self._driver.modify(socket.raw(), interest, token)

    def modify_raw(
        mut self, fd: RawHandle, interest: Interest, token: Token
    ) raises:
        """Replace the interest flags and token of a registered fd.

        Args:
            fd: The registered file descriptor.
            interest: New set of I/O events to watch for.
            token: New opaque token for subsequent notifications.

        Raises:
            If the descriptor is invalid, or not registered.
        """
        self._driver.modify(fd, interest, token)

    def deregister(mut self, ref socket: Socket) raises:
        """Remove a socket from the interest set.

        Args:
            socket: The registered socket to remove.

        Raises:
            If the socket is closed, or not registered.
        """
        self._driver.deregister(socket.raw())

    def deregister_raw(mut self, fd: RawHandle) raises:
        """Remove a bare file descriptor from the interest set.

        Args:
            fd: The registered file descriptor to remove.

        Raises:
            If the descriptor is invalid, or not registered.
        """
        self._driver.deregister(fd)

    def backend(self) -> Backend:
        """Return which kernel readiness mechanism backs this registry."""
        return self._driver.backend()

    def _wait(
        mut self, *, timeout_ms: Optional[UInt64]
    ) raises -> List[ReadinessEvent]:
        """Block until events are ready and return them.

        Private: waiting is the loop's job. A handler holds the registry
        while the loop is mid-dispatch, so exposing this would let a
        callback block inside its own dispatch and reorder events behind
        the loop's back.

        Args:
            timeout_ms: Maximum milliseconds to wait; None waits
                        forever, 0 returns immediately.

        Returns:
            The readiness events reported by this wait.
        """
        return self._driver.poll(timeout_ms=_driver_timeout(timeout_ms))


trait ReadinessHandler(Movable, Deinitable):
    """Callback interface for readiness events.

    `on_ready` receives the loop's registry by `mut`, so changing the
    interest set from inside a callback is an ordinary method call. The
    handler and the registry are distinct fields of the loop, so the two
    `mut` borrows never overlap — the old pointer-to-loop escape hatch,
    and the prose contract that guarded it, are gone.
    """

    def on_ready(
        mut self,
        mut registry: ReadinessRegistry,
        token: Token,
        readiness: Readiness,
    ):
        """Handle one readiness notification.

        Args:
            registry: The loop's interest set. Deregister, re-arm, or
                      change interest through it.
            token: The token supplied when the resource was registered.
            readiness: Which I/O operations are possible right now.
        """
        ...


struct ReadinessLoop[Handler: ReadinessHandler](Movable):
    """Opaque readiness event loop. Backend resolved at comptime.

    Registers resources with interest flags, then ticks to discover
    which ones are ready for I/O. You perform the actual I/O yourself
    after being notified. `run_once()` is one blocking tick, bounded by
    an optional `timeout_ms`; `poll()` is one non-blocking tick.

    The loop owns a `ReadinessRegistry` and the handler. Registration
    methods delegate to the registry; `registry()` and `handler()`
    hand out references for callers who need direct access.

    The underlying driver (epoll, kqueue, ...) is selected via the
    comptime `_ReadinessDriver` alias in `boucle.drivers`.
    """

    var _registry: ReadinessRegistry
    var _handler: Self.Handler

    def __init__(
        out self, var handler: Self.Handler, *, capacity: Int = 64
    ) raises:
        """Create a readiness loop with a fresh, empty registry.

        Args:
            handler: Callback object invoked for each readiness event.
            capacity: How many events one tick may report (default 64).
                      A hint: events beyond it are simply reported by
                      the next tick.
        """
        self._registry = ReadinessRegistry(capacity=capacity)
        self._handler = handler^

    def __init__(
        out self, var handler: Self.Handler, var registry: ReadinessRegistry
    ):
        """Create a readiness loop around an already-populated registry.

        Useful when resources must be registered before they are moved
        into the handler.

        Args:
            handler: Callback object invoked for each readiness event.
            registry: The interest set the loop takes ownership of.
        """
        self._registry = registry^
        self._handler = handler^

    def __init__(out self, *, deinit move: Self):
        self._registry = move._registry^
        self._handler = move._handler^

    def registry(ref self) -> ref [self._registry] ReadinessRegistry:
        """Return a reference to the loop's interest set."""
        return self._registry

    def handler(ref self) -> ref [self._handler] Self.Handler:
        """Return a reference to the loop's handler.

        Lets callers read back whatever state the handler accumulated
        across polls without reaching into private fields.
        """
        return self._handler

    def register(
        mut self, ref socket: Socket, interest: Interest, token: Token
    ) raises:
        """Add a socket to the interest set.

        Args:
            socket: The socket to monitor. Must outlive the registration.
            interest: Which I/O events to watch for.
            token: Opaque token returned on notification.

        Raises:
            If the socket is closed, or already registered.
        """
        self._registry.register(socket, interest, token)

    def register_raw(
        mut self, fd: RawHandle, interest: Interest, token: Token
    ) raises:
        """Add a bare file descriptor to the interest set.

        Args:
            fd: The file descriptor to monitor. Must stay open for as
                long as it is registered.
            interest: Which I/O events to watch for.
            token: Opaque token returned on notification.

        Raises:
            If the descriptor is invalid, or already registered.
        """
        self._registry.register_raw(fd, interest, token)

    def modify(
        mut self, ref socket: Socket, interest: Interest, token: Token
    ) raises:
        """Replace the interest flags and token of a registered socket.

        Args:
            socket: The registered socket.
            interest: New set of I/O events to watch for.
            token: New opaque token for subsequent notifications.

        Raises:
            If the socket is closed, or not registered.
        """
        self._registry.modify(socket, interest, token)

    def modify_raw(
        mut self, fd: RawHandle, interest: Interest, token: Token
    ) raises:
        """Replace the interest flags and token of a registered fd.

        Args:
            fd: The registered file descriptor.
            interest: New set of I/O events to watch for.
            token: New opaque token for subsequent notifications.

        Raises:
            If the descriptor is invalid, or not registered.
        """
        self._registry.modify_raw(fd, interest, token)

    def deregister(mut self, ref socket: Socket) raises:
        """Remove a socket from the interest set.

        Args:
            socket: The registered socket to remove.

        Raises:
            If the socket is closed, or not registered.
        """
        self._registry.deregister(socket)

    def deregister_raw(mut self, fd: RawHandle) raises:
        """Remove a bare file descriptor from the interest set.

        Args:
            fd: The registered file descriptor to remove.

        Raises:
            If the descriptor is invalid, or not registered.
        """
        self._registry.deregister_raw(fd)

    def backend(self) -> Backend:
        """Return which kernel readiness mechanism backs this loop."""
        return self._registry.backend()

    def run_once(mut self, *, timeout_ms: Optional[UInt64] = None) raises:
        """Run one blocking tick: wait for events, dispatch every one.

        Returns as soon as the first batch of events has been handled,
        or as soon as `timeout_ms` elapses with nothing ready.

        Args:
            timeout_ms: Maximum milliseconds to wait. None (the default)
                        waits until something is ready.
        """
        self._dispatch(timeout_ms)

    def run_once(mut self, *, timeout_ms: UInt64) raises:
        """Run one blocking tick, bounded by a plain millisecond count.

        Same as the `Optional` form; it exists so that a literal
        (`run_once(timeout_ms=100)`) needs no cast, since Mojo will not
        chain the two implicit conversions that would otherwise be
        required.

        Args:
            timeout_ms: Maximum milliseconds to wait; 0 returns at once.
        """
        self._dispatch(timeout_ms)

    def poll(mut self) raises:
        """Run one non-blocking tick.

        Dispatches the events that are already ready and returns, even
        when there are none. Equivalent to `run_once(timeout_ms=0)`,
        spelled the same way as on the completion loops.
        """
        self._dispatch(UInt64(0))

    def _dispatch(mut self, timeout_ms: Optional[UInt64]) raises:
        """Wait once and invoke the handler for each reported event.

        Each event is dispatched to `on_ready` with the registry, so a
        handler may deregister itself or change its interest mid-tick.
        Such a change takes effect on the next tick; the events already
        returned by this wait are still delivered.

        Args:
            timeout_ms: Maximum milliseconds to wait; None waits
                        forever, 0 returns immediately.
        """
        var events = self._registry._wait(timeout_ms=timeout_ms)
        for i in range(len(events)):
            self._handler.on_ready(
                self._registry,
                events[i].token,
                events[i].readiness,
            )
