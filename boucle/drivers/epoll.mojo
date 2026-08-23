"""Linux epoll backend for the ReadinessDriver trait.

Wraps epoll_create/epoll_ctl/epoll_wait and converts raw epoll_event
structs into portable ReadinessEvent values. Extracted from the
monolithic ReadinessLoop so the driver can be tested independently
and swapped for other backends (kqueue, IOCP) on other platforms.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.socle.linux.epoll.syscalls import (
    epoll_create,
    epoll_ctl,
    epoll_wait,
    EpollOp,
)
from boucle.socle.linux.raw import epoll_event, EPOLLRDHUP
from boucle.socle.linux.fd import close_unchecked
from boucle.handle import RawHandle
from boucle.interest import Interest
from boucle.token import Token
from boucle.readiness_state import Readiness
from boucle.drivers.backend import Backend
from boucle.drivers.driver import ReadinessDriver
from boucle.drivers.readiness_event import ReadinessEvent


struct EpollDriver(ReadinessDriver):
    """ReadinessDriver backed by Linux epoll.

    Manages an epoll instance and an internal event buffer.
    poll() returns a List[ReadinessEvent] by converting each
    raw epoll_event into the portable ReadinessEvent type.
    """

    var _epfd: Int32
    var _events: Pointer[epoll_event, MutUntrackedOrigin]
    var _max_events: Int32

    def __init__(out self, *, max_events: Int32 = 64) raises:
        """Create an epoll driver with the given event buffer capacity.

        Args:
            max_events: Maximum events returned per poll() call
                        (default 64).
        """
        self._epfd = epoll_create()
        self._max_events = max_events
        self._events = unsafe_alloc[epoll_event](Int(max_events))

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._epfd = move._epfd
        self._events = move._events
        self._max_events = move._max_events

    def __deinit__(deinit self):
        """Free the event buffer and close the epoll fd.

        Errors from close() are detected only in debug builds
        (via debug_assert inside close_unchecked).
        """
        self._events.unsafe_free()
        close_unchecked(unsafe_fd=self._epfd)

    def register(
        mut self, fd: RawHandle, interest: Interest, token: Token
    ) raises:
        """Add a file descriptor to the epoll interest list.

        Args:
            fd: The file descriptor to monitor.
            interest: Which I/O events to watch for. EPOLLRDHUP is
                      always added automatically.
            token: Opaque token stored as epoll_event data and returned
                   in ReadinessEvent on notification.
        """
        var ev = epoll_event(
            events=interest.value | EPOLLRDHUP,
            data=token.value,
        )
        epoll_ctl(self._epfd, EpollOp.ADD, fd, ev)

    def modify(
        mut self, fd: RawHandle, interest: Interest, token: Token
    ) raises:
        """Modify the interest flags for a registered file descriptor.

        Args:
            fd: The registered file descriptor.
            interest: New set of I/O events to watch for. EPOLLRDHUP is
                      always added automatically.
            token: New opaque token for subsequent notifications.
        """
        var ev = epoll_event(
            events=interest.value | EPOLLRDHUP,
            data=token.value,
        )
        epoll_ctl(self._epfd, EpollOp.MOD, fd, ev)

    def deregister(mut self, fd: RawHandle) raises:
        """Remove a file descriptor from the epoll interest list.

        Args:
            fd: The registered file descriptor to remove.
        """
        var ev = epoll_event()
        epoll_ctl(self._epfd, EpollOp.DEL, fd, ev)

    def poll(
        mut self, *, timeout_ms: Int32 = -1
    ) raises -> List[ReadinessEvent]:
        """Wait for readiness events and return them as a list.

        Calls epoll_wait, then converts each raw epoll_event into
        a ReadinessEvent with the stored token and readiness flags.

        Args:
            timeout_ms: Maximum milliseconds to wait (-1 = infinite,
                        0 = non-blocking).

        Returns:
            List of ReadinessEvent notifications from this poll cycle.
        """
        var n = epoll_wait(
            self._epfd,
            self._events,
            max_events=self._max_events,
            timeout=timeout_ms,
        )
        var result = List[ReadinessEvent](capacity=Int(n))
        for i in range(Int(n)):
            var ev = self._events[unsafe_offset=i]
            result.append(
                ReadinessEvent(Token(ev.data()), Readiness(ev.events))
            )
        return result^

    def backend(self) -> Backend:
        """Return Backend.EPOLL."""
        return Backend.EPOLL
