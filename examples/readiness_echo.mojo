"""Readiness-model echo example: pipe readable notification.

Demonstrates the ReadinessLoop API. Register a pipe's read end with
`Interest.READABLE`, write a small message to the write end, then poll.
The handler observes the readable event and reads the bytes itself —
boucle never owns the buffer in this model.

Run:
    uv run -- mojo run -I . -D ASSERT=all examples/readiness_echo.mojo
"""

from boucle.readiness import ReadinessLoop, ReadinessHandler
from boucle.interest import Interest
from boucle.readiness_state import Readiness
from boucle.token import Token
from boucle.socle.linux.raw import syscall, __NR_read, __NR_write, __NR_close
from std.ffi import external_call
from std.testing import assert_equal, assert_true


comptime _MSG: StaticString = "hello"
comptime _MSG_LEN: Int = 5


struct EchoHandler(ReadinessHandler):
    """Records the readable event and reads the message off the pipe."""

    var read_fd: Int32
    var got_event: Bool
    var bytes_read: Int
    var buf: Array[UInt8, 16]

    def __init__(out self, read_fd: Int32):
        self.read_fd = read_fd
        self.got_event = False
        self.bytes_read = 0
        self.buf = Array[UInt8, 16](fill=0)

    def __init__(out self, *, deinit move: Self):
        self.read_fd = move.read_fd
        self.got_event = move.got_event
        self.bytes_read = move.bytes_read
        self.buf = move.buf

    def on_ready(
        mut self,
        loop: Pointer[ReadinessLoop[Self], MutUntrackedOrigin],
        token: Token,
        readiness: Readiness,
    ):
        self.got_event = True
        if readiness.is_readable():
            var n = syscall[__NR_read, Scalar[DType.int64]](
                self.read_fd,
                Pointer(to=self.buf).unsafe_bitcast[UInt8](),
                UInt64(16),
            )
            self.bytes_read = Int(n)


def main() raises:
    # Create a pipe via libc pipe(2).
    var pipefd = Array[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        Pointer(to=pipefd).unsafe_bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var loop = ReadinessLoop(EchoHandler(read_fd), max_events=16)
    loop.register(read_fd, Interest.READABLE, Token(42))

    var msg_ptr = Pointer[UInt8, ImmStaticOrigin](
        unsafe_from_address=Int(_MSG.unsafe_ptr())
    )
    _ = syscall[__NR_write, Scalar[DType.int64]](write_fd, msg_ptr, UInt64(_MSG_LEN))

    loop.poll(timeout_ms=1000)

    assert_true(loop._handler.got_event)
    assert_equal(loop._handler.bytes_read, _MSG_LEN)
    # Verify byte content matches "hello"
    for i in range(_MSG_LEN):
        assert_equal(Int(loop._handler.buf[i]), Int(_MSG.unsafe_ptr()[i]))

    loop.deregister(read_fd)
    _ = syscall[__NR_close, Scalar[DType.int32]](read_fd)
    _ = syscall[__NR_close, Scalar[DType.int32]](write_fd)

    print("OK")
