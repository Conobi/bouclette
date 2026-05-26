"""Readiness-based I/O — get notified when I/O is possible, then do it yourself.

Best for:
  - Multiplexed connections (HTTP/2, HTTP/3, QUIC)
  - Frequent cancellation (timeouts, request racing)
  - Fine-grained scheduling (stream prioritization)

You retain buffer ownership at all times. Cancel by simply
stopping to poll.

See `boucle.completion` for the alternative model.
"""

from boucle._sys.linux.epoll.syscalls import (
    epoll_create,
    epoll_ctl,
    epoll_wait,
    EpollOp,
)
from boucle._sys.linux.raw import epoll_event, EPOLLRDHUP
from boucle._sys.linux.fd import close, close_unchecked
from boucle.interest import Interest
from boucle.readiness_state import Readiness
from boucle.token import Token
from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc


trait ReadinessHandler(Movable, ImplicitlyDestructible):
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
        loop: UnsafePointer[ReadinessLoop[Self], MutExternalOrigin],
        token: Token,
        readiness: Readiness,
    ):
        ...


struct ReadinessLoop[Handler: ReadinessHandler]:
    """Event loop driven by epoll readiness notifications.

    Register file descriptors with interest flags, then poll to
    discover which ones are ready for I/O. You perform the actual
    I/O yourself after being notified.
    """

    var _epfd: Int32
    var _events: UnsafePointer[epoll_event, MutExternalOrigin]
    var _max_events: Int32
    var _handler: Self.Handler

    def __init__(
        out self, var handler: Self.Handler, *, max_events: Int32 = 64
    ) raises:
        self._epfd = epoll_create()
        self._max_events = max_events
        self._events = alloc[epoll_event](Int(max_events))
        self._handler = handler^

    def __del__(deinit self):
        """Frees the event buffer and closes the epoll fd.

        Errors from close() are detected only in debug builds
        (via debug_assert inside close/unsafe_fd_as_arg).
        """
        self._events.free()
        close_unchecked(unsafe_fd=self._epfd)

    def register(self, fd: Int32, interest: Interest, token: Token) raises:
        """Add a file descriptor to the interest list."""
        var ev = epoll_event(
            events=interest.value | EPOLLRDHUP,
            data=token.value,
        )
        epoll_ctl(self._epfd, EpollOp.ADD, fd, ev)

    def modify(self, fd: Int32, interest: Interest, token: Token) raises:
        """Modify the interest flags for a registered file descriptor."""
        var ev = epoll_event(
            events=interest.value | EPOLLRDHUP,
            data=token.value,
        )
        epoll_ctl(self._epfd, EpollOp.MOD, fd, ev)

    def deregister(self, fd: Int32) raises:
        """Remove a file descriptor from the interest list."""
        var ev = epoll_event()
        epoll_ctl(self._epfd, EpollOp.DEL, fd, ev)

    def poll(mut self, *, timeout_ms: Int32 = -1) raises:
        """Wait for readiness events and invoke handler for each."""
        var n = epoll_wait(
            self._epfd,
            self._events,
            max_events=self._max_events,
            timeout=timeout_ms,
        )
        for i in range(Int(n)):
            var ev = self._events[i]
            # Construct a loop pointer with an unconstrained origin so it
            # doesn't alias with the `mut self._handler` borrow below.
            # Safety: the pointer is valid only for the duration of the
            # on_ready call; the loop outlives the handler invocation.
            var loop_ptr = UnsafePointer[Self, MutExternalOrigin](
                unsafe_from_address=Int(UnsafePointer(to=self))
            )
            self._handler.on_ready(
                loop_ptr,
                Token(ev.data()),
                Readiness(ev.events),
            )
