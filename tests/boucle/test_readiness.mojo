"""Tests for ReadinessLoop, ReadinessRegistry and the handler contract.

The handler never sees a pointer to the loop: `on_ready` receives the
registry by `mut`, so self-deregistration and interest changes are
ordinary, checked method calls. Handler state is read back through the
public `handler()` accessor.
"""

from boucle.readiness import ReadinessLoop, ReadinessHandler, ReadinessRegistry
from boucle.interest import Interest
from boucle.readiness_state import Readiness
from boucle.token import Token
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.socle.linux.fd import close
from boucle.socle.linux.raw import syscall, __NR_read, __NR_write
from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_raises


def _make_pipe() raises -> Array[Int32, 2]:
    """Create a POSIX pipe and return its (read_fd, write_fd) pair."""
    var pipefd = Array[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        Pointer(to=pipefd).unsafe_bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    return pipefd^


struct Tracker(ReadinessHandler):
    """Records the last readiness event it observed."""

    var count: Int
    var last_token: UInt64
    var last_readable: Bool
    var last_writable: Bool

    def __init__(out self):
        """Start with no events observed."""
        self.count = 0
        self.last_token = 0
        self.last_readable = False
        self.last_writable = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.count = move.count
        self.last_token = move.last_token
        self.last_readable = move.last_readable
        self.last_writable = move.last_writable

    def on_ready(
        mut self,
        mut registry: ReadinessRegistry,
        token: Token,
        readiness: Readiness,
    ):
        """Record the event; leave the interest set untouched."""
        self.count += 1
        self.last_token = token.value
        self.last_readable = readiness.is_readable()
        self.last_writable = readiness.is_writable()


def test_pipe_readable() raises:
    """A readable pipe end fires on_ready with its registered token."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Tracker(), capacity=16)
    loop.register_raw(read_fd, Interest.READABLE, Token(42))

    # Write a byte to make the read end readable (raw syscall to avoid
    # name collision with Mojo's stdlib).
    var msg = UInt8(1)
    _ = syscall[__NR_write, Scalar[DType.int64]](
        write_fd, Pointer(to=msg), UInt64(1)
    )

    loop.run_once(timeout_ms=100)
    assert_equal(loop.handler().count, 1)
    assert_equal(loop.handler().last_token, UInt64(42))
    assert_true(loop.handler().last_readable)
    assert_true(not loop.handler().last_writable)

    loop.deregister_raw(read_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_pipe_writable() raises:
    """A writable pipe end fires on_ready with its registered token."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Tracker(), capacity=16)
    loop.register_raw(write_fd, Interest.WRITABLE, Token(99))

    loop.run_once(timeout_ms=100)
    assert_equal(loop.handler().count, 1)
    assert_equal(loop.handler().last_token, UInt64(99))
    assert_true(loop.handler().last_writable)

    loop.deregister_raw(write_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_modify_interest() raises:
    """Modifying a registration replaces both interest flags and token."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Tracker(), capacity=16)
    loop.register_raw(write_fd, Interest.READABLE, Token(1))
    loop.run_once(timeout_ms=10)  # No events -- write end isn't readable.

    loop.modify_raw(write_fd, Interest.WRITABLE, Token(2))
    loop.run_once(timeout_ms=100)
    assert_equal(loop.handler().last_token, UInt64(2))
    assert_true(loop.handler().last_writable)

    loop.deregister_raw(write_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_register_socket_by_reference() raises:
    """A Socket registers without the caller reaching for its raw fd."""
    var server = Socket.tcp_v4()
    server.set_blocking(True)
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)
    var port = server.local_addr_v4().port

    var registry = ReadinessRegistry(capacity=16)
    registry.register(server, Interest.READABLE, Token(7))

    var loop = ReadinessLoop(Tracker(), registry^)
    var client = Socket.tcp_connect(SocketAddrV4(127, 0, 0, 1, port=port))

    loop.run_once(timeout_ms=1000)
    assert_equal(loop.handler().count, 1)
    assert_equal(loop.handler().last_token, UInt64(7))
    assert_true(loop.handler().last_readable)

    loop.deregister(server)
    client.close()
    server.close()


struct SelfDeregister(ReadinessHandler):
    """Drains the pipe and self-deregisters on its first readable event."""

    var read_fd: Int32
    var fired: Int
    var bytes_read: Int
    var dereg_failed: Bool

    def __init__(out self, read_fd: Int32):
        """Remember which fd to drain and later remove."""
        self.read_fd = read_fd
        self.fired = 0
        self.bytes_read = 0
        self.dereg_failed = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.read_fd = move.read_fd
        self.fired = move.fired
        self.bytes_read = move.bytes_read
        self.dereg_failed = move.dereg_failed

    def on_ready(
        mut self,
        mut registry: ReadinessRegistry,
        token: Token,
        readiness: Readiness,
    ):
        """Drain the pipe, then remove this fd from the interest set."""
        self.fired += 1
        var buf = Array[UInt8, 16](fill=0)
        var n = syscall[__NR_read, Scalar[DType.int64]](
            self.read_fd,
            Pointer(to=buf).unsafe_bitcast[UInt8](),
            UInt64(16),
        )
        self.bytes_read = Int(n)
        try:
            registry.deregister_raw(self.read_fd)
        except:
            self.dereg_failed = True


def test_self_deregister_in_on_ready() raises:
    """A handler can remove itself from the interest set mid-dispatch."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(SelfDeregister(read_fd), capacity=16)
    loop.register_raw(read_fd, Interest.READABLE, Token(77))

    var msg = UInt8(7)
    _ = syscall[__NR_write, Scalar[DType.int64]](
        write_fd, Pointer(to=msg), UInt64(1)
    )

    loop.run_once(timeout_ms=100)
    assert_equal(loop.handler().fired, 1)
    assert_equal(loop.handler().bytes_read, 1)
    assert_true(not loop.handler().dereg_failed)

    # The fd was deregistered inside on_ready; a further poll must not
    # re-fire the handler.
    loop.run_once(timeout_ms=10)
    assert_equal(loop.handler().fired, 1)

    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


struct SelfModifier(ReadinessHandler):
    """Swaps its own interest from writable to readable on first event."""

    var write_fd: Int32
    var fired: Int
    var tokens: Array[UInt64, 4]
    var modify_failed: Bool

    def __init__(out self, write_fd: Int32):
        """Remember which fd to re-arm with a different interest."""
        self.write_fd = write_fd
        self.fired = 0
        self.tokens = Array[UInt64, 4](fill=0)
        self.modify_failed = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.write_fd = move.write_fd
        self.fired = move.fired
        self.tokens = move.tokens^
        self.modify_failed = move.modify_failed

    def on_ready(
        mut self,
        mut registry: ReadinessRegistry,
        token: Token,
        readiness: Readiness,
    ):
        """Record the token, then narrow the interest to readable only."""
        if self.fired < 4:
            self.tokens[self.fired] = token.value
        self.fired += 1
        try:
            registry.modify_raw(
                self.write_fd, Interest.READABLE, Token(2)
            )
        except:
            self.modify_failed = True


def test_modify_interest_in_on_ready() raises:
    """A handler can change its own interest mid-dispatch."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(SelfModifier(write_fd), capacity=16)
    loop.register_raw(write_fd, Interest.WRITABLE, Token(1))

    loop.run_once(timeout_ms=100)
    assert_equal(loop.handler().fired, 1)
    assert_equal(loop.handler().tokens[0], UInt64(1))
    assert_true(not loop.handler().modify_failed)

    # Now only READABLE is watched; the write end of a pipe never becomes
    # readable, so the handler must stay silent.
    loop.run_once(timeout_ms=10)
    assert_equal(loop.handler().fired, 1)

    loop.deregister_raw(write_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_duplicate_fd_registration_raises() raises:
    """Registering the same fd twice is rejected by the kernel."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Tracker(), capacity=16)
    loop.register_raw(read_fd, Interest.READABLE, Token(1))
    with assert_raises():
        loop.register_raw(read_fd, Interest.READABLE, Token(2))

    loop.deregister_raw(read_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_same_token_for_two_fds() raises:
    """A token is opaque: reusing one for two fds is legal, not an error."""
    var first = _make_pipe()
    var second = _make_pipe()

    var loop = ReadinessLoop(Tracker(), capacity=16)
    loop.register_raw(first[1], Interest.WRITABLE, Token(5))
    loop.register_raw(second[1], Interest.WRITABLE, Token(5))

    loop.run_once(timeout_ms=100)
    # Both write ends are writable, so the handler fires twice with the
    # same token -- correlation is the caller's responsibility.
    assert_equal(loop.handler().count, 2)
    assert_equal(loop.handler().last_token, UInt64(5))

    loop.deregister_raw(first[1])
    loop.deregister_raw(second[1])
    for i in range(2):
        close(unsafe_fd=first[i])
        close(unsafe_fd=second[i])


def test_deregister_unknown_fd_raises() raises:
    """Deregistering an fd that was never registered raises."""
    var pipefd = _make_pipe()
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Tracker(), capacity=16)
    with assert_raises():
        loop.deregister_raw(read_fd)

    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def main() raises:
    test_pipe_readable()
    test_pipe_writable()
    test_modify_interest()
    test_register_socket_by_reference()
    test_self_deregister_in_on_ready()
    test_modify_interest_in_on_ready()
    test_duplicate_fd_registration_raises()
    test_same_token_for_two_fds()
    test_deregister_unknown_fd_raises()
    print("All readiness loop tests passed.")
