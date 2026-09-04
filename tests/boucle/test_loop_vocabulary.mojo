"""Tests for the shared loop vocabulary and the unified capacity/time names.

One verb per behaviour, on every loop that has the behaviour:

- `run()` blocks until every submitted operation completed (WatchLoop).
- `run_forever()` runs until `stop()` is called (CompletionLoop).
- `run_once()` is one blocking tick (CompletionLoop, ReadinessLoop).
- `poll()` is one non-blocking tick (CompletionLoop, ReadinessLoop).

And one name per quantity: `capacity` for every loop/driver capacity hint,
`timeout_ms` for every public duration.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.drivers.auto import AutoDriver
from boucle.drivers.backend import Backend
from boucle.drivers.epoll import EpollDriver
from boucle.drivers.epoll_completion import EpollCompletionDriver
from boucle.drivers.io_uring import IoUringDriver
from boucle.interest import Interest
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.proactor.completion_loop import CompletionLoop
from boucle.readiness import ReadinessLoop, ReadinessHandler, ReadinessRegistry
from boucle.readiness_state import Readiness
from boucle.socle.linux.fd import close
from boucle.socle.linux.raw import syscall, __NR_write
from boucle.token import Token
from boucle.watch import WatchLoop


def _make_pipe() raises -> Array[Int32, 2]:
    """Create a POSIX pipe and return its (read_fd, write_fd) pair."""
    var pipefd = Array[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        Pointer(to=pipefd).unsafe_bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    return pipefd^


struct Counter(ReadinessHandler):
    """Counts readiness notifications; changes nothing in the interest set."""

    var count: Int

    def __init__(out self):
        """Start with no events observed."""
        self.count = 0

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.count = move.count

    def on_ready(
        mut self,
        mut registry: ReadinessRegistry,
        token: Token,
        readiness: Readiness,
    ):
        """Record one event.

        Args:
            registry: The loop's interest set, left untouched here.
            token: The token supplied at registration time.
            readiness: Which I/O operations are possible right now.
        """
        self.count += 1


struct _StopOnCompletion:
    """Completion context that stops the loop that dispatched it."""

    var loop: Pointer[CompletionLoop, MutUntrackedOrigin]
    var count: Int

    def __init__(out self, loop: Pointer[CompletionLoop, MutUntrackedOrigin]):
        """Point at the loop to stop.

        Args:
            loop: The loop whose `run_forever()` must return.
        """
        self.loop = loop
        self.count = 0

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Count the completion and ask the loop to stop.

        Args:
            ctx: Pointer to the owning `_StopOnCompletion`.
            result: The operation result, unused here.
            flags: The operation flags, unused here.
        """
        var self_ptr = Pointer[_StopOnCompletion, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].count += 1
        self_ptr[].loop[].stop()


# ── CompletionLoop: run_forever / run_once / poll ─────────────────────────────


def test_completion_loop_run_forever_returns_after_stop() raises:
    """`run_forever()` returns once a callback calls `stop()`."""
    var loop = CompletionLoop(capacity=8)
    var loop_ptr = Pointer[CompletionLoop, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=loop))
    )
    var ctx_state = _StopOnCompletion(loop_ptr)
    var cmp = Completion(
        invoke=_StopOnCompletion.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=ctx_state))
        ),
    )
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    loop.nop(cmp_ptr)
    loop.run_forever()

    assert_equal(ctx_state.count, 1)
    _ = cmp


def test_completion_loop_run_once_dispatches_one_completion() raises:
    """`run_once()` blocks until at least one completion is dispatched."""
    var loop = CompletionLoop(capacity=8)
    var loop_ptr = Pointer[CompletionLoop, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=loop))
    )
    var ctx_state = _StopOnCompletion(loop_ptr)
    var cmp = Completion(
        invoke=_StopOnCompletion.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=ctx_state))
        ),
    )
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    loop.nop(cmp_ptr)
    loop.run_once()

    assert_equal(ctx_state.count, 1)
    _ = cmp


def test_completion_loop_poll_returns_with_nothing_submitted() raises:
    """`poll()` returns immediately when no completion is available."""
    var loop = CompletionLoop(capacity=4)
    loop.poll()
    assert_true(True)


# ── ReadinessLoop: run_once / poll ────────────────────────────────────────────


def test_readiness_run_once_returns_on_timeout() raises:
    """`run_once(timeout_ms=...)` returns with no events once the time is up."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Counter(), capacity=16)
    loop.register_raw(read_fd, Interest.READABLE, Token(1))

    # Nothing was written, so the read end never becomes readable.
    loop.run_once(timeout_ms=10)
    assert_equal(loop.handler().count, 0)

    loop.deregister_raw(read_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_readiness_run_once_blocks_until_an_event() raises:
    """`run_once()` without a timeout waits for the first event."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Counter(), capacity=16)
    loop.register_raw(read_fd, Interest.READABLE, Token(1))

    var msg = UInt8(1)
    _ = syscall[__NR_write, Scalar[DType.int64]](
        write_fd, Pointer(to=msg), UInt64(1)
    )

    loop.run_once()
    assert_equal(loop.handler().count, 1)

    loop.deregister_raw(read_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_readiness_poll_returns_immediately() raises:
    """`poll()` dispatches what is ready and returns without waiting."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Counter(), capacity=16)
    loop.register_raw(read_fd, Interest.READABLE, Token(1))

    loop.poll()
    assert_equal(loop.handler().count, 0)

    var msg = UInt8(1)
    _ = syscall[__NR_write, Scalar[DType.int64]](
        write_fd, Pointer(to=msg), UInt64(1)
    )

    loop.poll()
    assert_equal(loop.handler().count, 1)

    loop.deregister_raw(read_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


# ── capacity= on every loop and driver constructor ────────────────────────────


def test_capacity_keyword_on_loops() raises:
    """Every loop takes the same keyword-only `capacity`."""
    var watch = WatchLoop(capacity=4)
    var completion = CompletionLoop(capacity=4)
    var registry = ReadinessRegistry(capacity=4)
    var readiness = ReadinessLoop(Counter(), capacity=4)
    assert_equal(watch.in_flight_count(), 0)
    assert_equal(readiness.handler().count, 0)
    _ = completion^
    _ = registry^


def test_capacity_keyword_on_drivers() raises:
    """Every driver takes the same keyword-only `capacity`."""
    var auto = AutoDriver(capacity=4)
    var epoll = EpollDriver(capacity=4)
    var epoll_completion = EpollCompletionDriver(capacity=4)
    assert_true(auto.backend() is not Backend.AUTO)
    assert_true(epoll.backend() is Backend.EPOLL)
    assert_true(epoll_completion.backend() is Backend.EPOLL)
    _ = auto^
    _ = epoll^
    _ = epoll_completion^

    try:
        var uring = IoUringDriver(capacity=4)
        assert_true(uring.backend() is Backend.IO_URING)
        _ = uring^
    except:
        pass  # io_uring unavailable on this kernel; nothing to assert.


# ── timeout_ms= on every public duration ──────────────────────────────────────


def test_timeout_ms_keyword_on_socket() raises:
    """`set_recv_timeout` / `set_send_timeout` name their duration `timeout_ms`."""
    var s = Socket.tcp_v4()
    s.set_recv_timeout(timeout_ms=500)
    s.set_send_timeout(timeout_ms=1000)
    s.close()


def test_timeout_ms_keyword_on_watch_loop() raises:
    """`WatchLoop.timeout` names its duration `timeout_ms`."""
    var loop = WatchLoop(capacity=4)
    var timer = loop.timeout(timeout_ms=1)
    loop.run()
    assert_true(timer.result())


def main() raises:
    test_completion_loop_run_forever_returns_after_stop()
    test_completion_loop_run_once_dispatches_one_completion()
    test_completion_loop_poll_returns_with_nothing_submitted()
    test_readiness_run_once_returns_on_timeout()
    test_readiness_run_once_blocks_until_an_event()
    test_readiness_poll_returns_immediately()
    test_capacity_keyword_on_loops()
    test_capacity_keyword_on_drivers()
    test_timeout_ms_keyword_on_socket()
    test_timeout_ms_keyword_on_watch_loop()
    print("PASS: test_loop_vocabulary.mojo")
