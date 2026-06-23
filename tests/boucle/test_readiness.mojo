from boucle.readiness import ReadinessLoop, ReadinessHandler
from boucle.interest import Interest
from boucle.readiness_state import Readiness
from boucle.token import Token
from boucle._sys.linux.fd import close
from boucle._sys.linux.raw import syscall
from std.ffi import external_call
from std.testing import assert_equal, assert_true


struct Tracker(ReadinessHandler):
    var count: Int
    var last_token: UInt64
    var last_readable: Bool
    var last_writable: Bool

    def __init__(out self):
        self.count = 0
        self.last_token = 0
        self.last_readable = False
        self.last_writable = False

    def __init__(out self, *, deinit take: Self):
        self.count = take.count
        self.last_token = take.last_token
        self.last_readable = take.last_readable
        self.last_writable = take.last_writable

    def on_ready(
        mut self,
        loop: UnsafePointer[ReadinessLoop[Self], MutUntrackedOrigin],
        token: Token,
        readiness: Readiness,
    ):
        self.count += 1
        self.last_token = token.value
        self.last_readable = readiness.is_readable()
        self.last_writable = readiness.is_writable()


def test_pipe_readable() raises:
    var pipefd = InlineArray[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        UnsafePointer(to=pipefd).bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Tracker(), max_events=16)
    loop.register(read_fd, Interest.READABLE, Token(42))

    # Write a byte to make read end readable (use raw syscall to avoid
    # name collision with Mojo's stdlib).
    var msg = UInt8(1)
    _ = syscall[1, Scalar[DType.int64]](write_fd, UnsafePointer(to=msg), UInt64(1))

    loop.poll(timeout_ms=100)
    assert_equal(loop._handler.count, 1)
    assert_equal(loop._handler.last_token, UInt64(42))
    assert_true(loop._handler.last_readable)
    assert_true(not loop._handler.last_writable)

    loop.deregister(read_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_pipe_writable() raises:
    var pipefd = InlineArray[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        UnsafePointer(to=pipefd).bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Tracker(), max_events=16)
    loop.register(write_fd, Interest.WRITABLE, Token(99))

    loop.poll(timeout_ms=100)
    assert_equal(loop._handler.count, 1)
    assert_equal(loop._handler.last_token, UInt64(99))
    assert_true(loop._handler.last_writable)

    loop.deregister(write_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_modify_interest() raises:
    var pipefd = InlineArray[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        UnsafePointer(to=pipefd).bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(Tracker(), max_events=16)
    loop.register(write_fd, Interest.READABLE, Token(1))
    loop.poll(timeout_ms=10)  # No events -- write end isn't readable

    loop.modify(write_fd, Interest.WRITABLE, Token(2))
    loop.poll(timeout_ms=100)
    assert_equal(loop._handler.last_token, UInt64(2))
    assert_true(loop._handler.last_writable)

    loop.deregister(write_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


struct SelfDeregister(ReadinessHandler):
    """Drains the pipe and self-deregisters on first readable event."""

    var read_fd: Int32
    var fired: Int
    var bytes_read: Int
    var dereg_failed: Bool

    def __init__(out self, read_fd: Int32):
        self.read_fd = read_fd
        self.fired = 0
        self.bytes_read = 0
        self.dereg_failed = False

    def __init__(out self, *, deinit take: Self):
        self.read_fd = take.read_fd
        self.fired = take.fired
        self.bytes_read = take.bytes_read
        self.dereg_failed = take.dereg_failed

    def on_ready(
        mut self,
        loop: UnsafePointer[ReadinessLoop[Self], MutUntrackedOrigin],
        token: Token,
        readiness: Readiness,
    ):
        self.fired += 1
        # Drain the pipe so subsequent polls don't re-fire on the same data.
        var buf = InlineArray[UInt8, 16](fill=0)
        var n = syscall[0, Scalar[DType.int64]](
            self.read_fd,
            UnsafePointer(to=buf).bitcast[UInt8](),
            UInt64(16),
        )
        self.bytes_read = Int(n)
        # Self-deregister via the loop pointer.
        try:
            loop[].deregister(self.read_fd)
        except:
            self.dereg_failed = True


def test_self_deregister_in_on_ready() raises:
    var pipefd = InlineArray[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        UnsafePointer(to=pipefd).bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(SelfDeregister(read_fd), max_events=16)
    loop.register(read_fd, Interest.READABLE, Token(77))

    # Write a byte so the read end becomes readable.
    var msg = UInt8(7)
    _ = syscall[1, Scalar[DType.int64]](write_fd, UnsafePointer(to=msg), UInt64(1))

    loop.poll(timeout_ms=100)
    assert_equal(loop._handler.fired, 1)
    assert_equal(loop._handler.bytes_read, 1)
    assert_true(not loop._handler.dereg_failed)

    # The fd was deregistered inside on_ready. A subsequent poll with a
    # short timeout should return no events (handler must NOT fire again).
    loop.poll(timeout_ms=10)
    assert_equal(loop._handler.fired, 1)

    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def main() raises:
    test_pipe_readable()
    test_pipe_writable()
    test_modify_interest()
    test_self_deregister_in_on_ready()
    print("All readiness loop tests passed.")
