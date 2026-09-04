"""Tests for EpollDriver — the ReadinessDriver backed by Linux epoll."""

from boucle.drivers.epoll import EpollDriver
from boucle.drivers.readiness_event import ReadinessEvent
from boucle.interest import Interest
from boucle.token import Token
from boucle.socle.linux.fd import close
from boucle.socle.linux.raw import syscall, __NR_write
from std.ffi import external_call
from std.testing import assert_equal, assert_true


def test_create_and_destroy() raises:
    """EpollDriver can be created and dropped without error."""
    var driver = EpollDriver(capacity=16)
    _ = driver^


def test_poll_empty_returns_no_events() raises:
    """Polling with no registered fds and zero timeout returns empty."""
    var driver = EpollDriver(capacity=16)
    var events = driver.poll(timeout_ms=0)
    assert_equal(len(events), 0)


def test_pipe_readable() raises:
    """Registering the read end of a pipe and writing a byte yields a readable event."""
    var pipefd = Array[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        Pointer(to=pipefd).unsafe_bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var driver = EpollDriver(capacity=16)
    driver.register(read_fd, Interest.READABLE, Token(42))

    # Write a byte to make read end readable.
    var msg = UInt8(1)
    _ = syscall[__NR_write, Scalar[DType.int64]](
        write_fd, Pointer(to=msg), UInt64(1)
    )

    var events = driver.poll(timeout_ms=100)
    assert_equal(len(events), 1)
    assert_equal(events[0].token.value, UInt64(42))
    assert_true(events[0].readiness.is_readable())
    assert_true(not events[0].readiness.is_writable())

    driver.deregister(read_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_pipe_writable() raises:
    """Registering the write end of a pipe yields a writable event."""
    var pipefd = Array[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        Pointer(to=pipefd).unsafe_bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var driver = EpollDriver(capacity=16)
    driver.register(write_fd, Interest.WRITABLE, Token(99))

    var events = driver.poll(timeout_ms=100)
    assert_equal(len(events), 1)
    assert_equal(events[0].token.value, UInt64(99))
    assert_true(events[0].readiness.is_writable())

    driver.deregister(write_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_modify_interest() raises:
    """Modifying interest from READABLE to WRITABLE changes reported events."""
    var pipefd = Array[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        Pointer(to=pipefd).unsafe_bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var driver = EpollDriver(capacity=16)

    # Register write end for READABLE — pipe write end is not readable,
    # so a short poll should return nothing.
    driver.register(write_fd, Interest.READABLE, Token(1))
    var events = driver.poll(timeout_ms=10)
    assert_equal(len(events), 0)

    # Modify to WRITABLE — write end is always writable when pipe buffer
    # has space.
    driver.modify(write_fd, Interest.WRITABLE, Token(2))
    events = driver.poll(timeout_ms=100)
    assert_equal(len(events), 1)
    assert_equal(events[0].token.value, UInt64(2))
    assert_true(events[0].readiness.is_writable())

    driver.deregister(write_fd)
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_deregister_stops_events() raises:
    """Deregistering a fd stops subsequent poll() from returning events for it."""
    var pipefd = Array[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        Pointer(to=pipefd).unsafe_bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var driver = EpollDriver(capacity=16)
    driver.register(write_fd, Interest.WRITABLE, Token(55))

    # Confirm we get an event.
    var events = driver.poll(timeout_ms=100)
    assert_equal(len(events), 1)

    # Deregister, then poll should return empty.
    driver.deregister(write_fd)
    events = driver.poll(timeout_ms=10)
    assert_equal(len(events), 0)

    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)


def test_multiple_fds() raises:
    """Multiple registered fds can return events in a single poll."""
    var pipe1 = Array[Int32, 2](fill=0)
    var pipe2 = Array[Int32, 2](fill=0)
    var r1 = external_call["pipe", Int32](
        Pointer(to=pipe1).unsafe_bitcast[Int32]()
    )
    var r2 = external_call["pipe", Int32](
        Pointer(to=pipe2).unsafe_bitcast[Int32]()
    )
    assert_equal(Int(r1), 0)
    assert_equal(Int(r2), 0)

    var driver = EpollDriver(capacity=16)
    driver.register(pipe1[1], Interest.WRITABLE, Token(10))
    driver.register(pipe2[1], Interest.WRITABLE, Token(20))

    var events = driver.poll(timeout_ms=100)
    assert_equal(len(events), 2)

    # Both tokens must appear (order is not guaranteed).
    var saw_10 = False
    var saw_20 = False
    for i in range(len(events)):
        if events[i].token.value == UInt64(10):
            saw_10 = True
        if events[i].token.value == UInt64(20):
            saw_20 = True
    assert_true(saw_10)
    assert_true(saw_20)

    driver.deregister(pipe1[1])
    driver.deregister(pipe2[1])
    close(unsafe_fd=pipe1[0])
    close(unsafe_fd=pipe1[1])
    close(unsafe_fd=pipe2[0])
    close(unsafe_fd=pipe2[1])


def main() raises:
    test_create_and_destroy()
    test_poll_empty_returns_no_events()
    test_pipe_readable()
    test_pipe_writable()
    test_modify_interest()
    test_deregister_stops_events()
    test_multiple_fds()
    print("All EpollDriver tests passed.")
