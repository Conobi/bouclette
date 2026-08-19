"""Readiness-model echo: socket readable notification.

Demonstrates the ReadinessLoop API. Register a socket with
Interest.READABLE, send a message to the other end, then poll.
The handler observes the readable event and reads the bytes itself —
boucle never owns the buffer in this model.

Run:
    uv run -- mojo run -I . -D ASSERT=all examples/readiness_echo.mojo
"""

from boucle.readiness import ReadinessLoop, ReadinessHandler
from boucle.interest import Interest
from boucle.readiness_state import Readiness
from boucle.token import Token
from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true


comptime _MSG: StaticString = "hello"
comptime _MSG_LEN: Int = 5


struct EchoHandler(ReadinessHandler):
    """Records the readable event and reads the message off the socket."""

    var read_fd: Int32
    var got_event: Bool
    var bytes_read: Int
    var buf: Array[UInt8, 16]

    def __init__(out self, read_fd: Int32):
        """Construct a handler that reads from the given fd."""
        self.read_fd = read_fd
        self.got_event = False
        self.bytes_read = 0
        self.buf = Array[UInt8, 16](fill=0)

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.read_fd = move.read_fd
        self.got_event = move.got_event
        self.bytes_read = move.bytes_read
        self.buf = move.buf^

    def on_ready(
        mut self,
        loop: Pointer[ReadinessLoop[Self], MutUntrackedOrigin],
        token: Token,
        readiness: Readiness,
    ):
        """Handle a readiness event by reading from the socket."""
        self.got_event = True
        if readiness.is_readable():
            var buf_ptr = Pointer(to=self.buf).unsafe_bitcast[UInt8]()
            var n = external_call["recv", Int64](
                self.read_fd, buf_ptr, UInt64(16), Int32(0)
            )
            self.bytes_read = Int(n)


def main() raises:
    # Create a connected AF_UNIX socketpair.
    var sv = Array[Int32, 2](fill=0)
    var res = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1),  # SOCK_STREAM
        Int32(0),
        Pointer(to=sv).unsafe_bitcast[Int32](),
    )
    assert_equal(Int(res), 0)
    var read_fd = sv[0]
    var write_fd = sv[1]

    var loop = ReadinessLoop(EchoHandler(read_fd), max_events=16)
    loop.register(read_fd, Interest.READABLE, Token(42))

    # Send the message via the write end.
    var msg_ptr = Pointer[UInt8, ImmStaticOrigin](
        unsafe_from_address=Int(_MSG.unsafe_ptr())
    )
    _ = external_call["send", Int64](
        write_fd, msg_ptr, UInt64(_MSG_LEN), Int32(0)
    )

    loop.poll(timeout_ms=1000)

    assert_true(loop._handler.got_event)
    assert_equal(loop._handler.bytes_read, _MSG_LEN)
    for i in range(_MSG_LEN):
        assert_equal(
            Int(loop._handler.buf[i]),
            Int(_MSG.unsafe_ptr()[unsafe_offset=i]),
        )

    loop.deregister(read_fd)
    _ = external_call["close", Int32](read_fd)
    _ = external_call["close", Int32](write_fd)

    print("OK")
