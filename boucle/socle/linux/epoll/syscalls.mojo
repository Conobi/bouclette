"""Linux epoll syscall wrappers.

Unlike io_uring, the epoll_* functions are libc wrappers (invoked through
`external_call`), not raw syscalls. On failure they return -1 and set the
thread-local errno; callers read it via `get_errno()`. `epoll_wait` is
restartable, so we retry transparently on EINTR — losing a tick because
SIGCHLD fired is not acceptable for a real event loop.
"""

from std.ffi import external_call
from boucle.socle.linux.raw import epoll_event, EINTR
from boucle.socle.linux.errno import get_errno


@fieldwise_init
struct EpollOp(ImplicitlyCopyable, Movable):
    """Epoll_ctl operation constants."""
    comptime ADD = Self(1)
    comptime DEL = Self(2)
    comptime MOD = Self(3)

    var value: Int32


@always_inline
def epoll_create() raises -> Int32:
    """Creates an epoll instance with CLOEXEC flag."""
    var res = external_call["epoll_create1", Int32](Int32(0x80000))  # O_CLOEXEC
    if res < 0:
        raise t"epoll_create1 failed with errno={Int(get_errno())}"
    return res


@always_inline
def epoll_ctl(
    epfd: Int32, op: EpollOp, fd: Int32, ref event: epoll_event
) raises:
    """Add, modify, or remove a file descriptor from the epoll interest list."""
    # Bind &event first: inlining Pointer(to=event) into the
    # external_call arg list risks losing the stack address mid-marshal.
    var event_p = Pointer(to=event).unsafe_bitcast[epoll_event]()
    var res = external_call["epoll_ctl", Int32](
        epfd,
        op.value,
        fd,
        event_p,
    )
    if res < 0:
        raise t"epoll_ctl failed with errno={Int(get_errno())}"


@always_inline
def epoll_wait(
    epfd: Int32,
    events: Pointer[epoll_event, ...],
    *,
    max_events: Int32,
    timeout: Int32 = -1,
) raises -> Int32:
    """Wait for events on the epoll instance.

    Returns the number of ready file descriptors. Retries transparently
    if interrupted by a signal (EINTR).
    """
    while True:
        var res = external_call["epoll_wait", Int32](
            epfd, events, max_events, timeout
        )
        if res >= 0:
            return res
        var e = get_errno()
        if e == Int32(EINTR):
            continue
        raise t"epoll_wait failed with errno={Int(e)}"
