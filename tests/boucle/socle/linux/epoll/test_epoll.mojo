from boucle.socle.linux.epoll.syscalls import (
    epoll_create, epoll_ctl, epoll_wait, EpollOp,
)
from boucle.socle.linux.raw import (
    epoll_event, EPOLLIN,
)
from boucle.socle.linux.raw import syscall
from boucle.socle.linux.fd import close
from std.ffi import external_call
from std.testing import assert_true, assert_equal

# __NR_write on x86_64
comptime __NR_write = 1


def test_epoll() raises:
    # Create epoll instance
    var epfd = epoll_create()
    assert_true(epfd > -1)

    # Create a pipe to watch
    var pipefd = InlineArray[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        UnsafePointer(to=pipefd).bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    # Register read end for EPOLLIN
    var ev = epoll_event(events=EPOLLIN, data=UInt64(42))
    epoll_ctl(epfd, EpollOp.ADD, read_fd, ev)

    # Write to pipe so read end becomes readable (use raw syscall to avoid
    # symbol conflict with stdlib's internal "write" external_call)
    var msg = UInt8(1)
    _ = syscall[__NR_write, Int64](
        write_fd, UnsafePointer(to=msg), UInt64(1)
    )

    # Wait for events
    var events = InlineArray[epoll_event, 4](fill=epoll_event())
    var n = epoll_wait(
        epfd,
        UnsafePointer(to=events).bitcast[epoll_event](),
        max_events=4,
        timeout=100,
    )
    assert_equal(n, Int32(1))
    assert_equal(events[0].data(), UInt64(42))
    assert_true(Int(events[0].events) & EPOLLIN != 0)

    # Cleanup
    close(unsafe_fd=read_fd)
    close(unsafe_fd=write_fd)
    close(unsafe_fd=epfd)


def main() raises:
    test_epoll()
    print("PASS: test_epoll.mojo")
