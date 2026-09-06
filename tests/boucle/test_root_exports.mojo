"""Pin the public surface of the `boucle` root package.

Every symbol a user needs to write watch-based, readiness-based or
coroutine-based I/O must be importable from `boucle` directly, and
nothing from the private `socle` layer or from the raw driver
plumbing may be reachable there. This test imports the whole intended
surface: it stops compiling the day an export is dropped or renamed.
"""

from boucle import (
    AddrFamily,
    Backend,
    Coroutine,
    CoroutineBody,
    Interest,
    IOError,
    IpAddrV4,
    IpAddrV6,
    OwnedHandle,
    RawHandle,
    Readiness,
    ReadinessHandler,
    ReadinessLoop,
    ReadinessRegistry,
    Socket,
    SocketAddrV4,
    SocketAddrV6,
    StackPool,
    Token,
    Yielder,
)
from boucle import (
    AcceptFuture,
    BufferPool,
    ConnectFuture,
    ConnectOutcome,
    ConnectWithTimeoutFuture,
    ControlMessage,
    ControlMessages,
    Datagram,
    DatagramStream,
    DeliveryHeader,
    FailureReason,
    LeasedBuffer,
    Message,
    MessageFailed,
    MessageResult,
    RecvFuture,
    RecvMsgFuture,
    SendFuture,
    SendMsgFuture,
    TimerFuture,
    TransferFailed,
    TransferResult,
    WatchLoop,
)
from std.testing import assert_equal, assert_not_equal, assert_true


def test_backend_is_writable() raises:
    """Backend must print its mechanism name, not its numeric id."""
    assert_equal(String(Backend.AUTO), "auto")
    assert_equal(String(Backend.IO_URING), "io_uring")
    assert_equal(String(Backend.EPOLL), "epoll")


def test_backend_is_equatable() raises:
    """Backend must compare by mechanism, so users can assert on it."""
    assert_equal(Backend.EPOLL, Backend.EPOLL)
    assert_not_equal(Backend.EPOLL, Backend.IO_URING)
    assert_true(Backend.AUTO == Backend.AUTO)
    assert_true(Backend.AUTO != Backend.EPOLL)


def test_watch_loop_reports_its_backend() raises:
    """The loop's backend must be readable and printable from the root API."""
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    assert_equal(String(loop.backend()), "epoll")


def test_root_exports_are_usable() raises:
    """The exported types must be constructible, not just importable."""
    var token = Token(7)
    assert_equal(token.value, 7)
    var addr = SocketAddrV4(127, 0, 0, 1, port=0)
    assert_equal(String(addr.ip), "127.0.0.1")
    assert_true(Interest.READABLE.is_readable())
    var msg = Message(List[UInt8](length=1, fill=0), control_capacity=24)
    msg.set_peer(addr)
    msg.set_ecn(1)
    assert_equal(Int(msg.control().ecn().value()), 1)
    assert_equal(String(FailureReason.LOOP_GONE), "LOOP_GONE")
    assert_true(AddrFamily.INET != AddrFamily.INET6)
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    var pool = loop.buffer_pool(2, 64)
    assert_equal(pool.capacity(), 2)
    var hdr_buf = List[UInt8](length=16, fill=0)
    var hdr = DeliveryHeader.parse(
        Span(hdr_buf), name_capacity=0, control_capacity=0
    )
    assert_equal(Int(hdr.payloadlen()), 0)
    _ = pool^
    _ = loop^


def main() raises:
    test_backend_is_writable()
    test_backend_is_equatable()
    test_watch_loop_reports_its_backend()
    test_root_exports_are_usable()
    print("PASS: test_root_exports.mojo")
