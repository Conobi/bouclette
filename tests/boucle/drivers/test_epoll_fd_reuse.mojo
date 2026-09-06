"""An op armed on a socket the user closed must not detach a later op on the reused fd number.

Sequence: an op is armed on socket A (fd N); the user closes A, so the
kernel silently drops A's epoll registration; socket B is created and
receives the same number N; an op is armed on B; the stale op on A is
cancelled. The cancel must retire only A's own registration. If the
driver instead issued EPOLL_CTL_DEL on the number N it remembered, it
would strip B's registration, B's completion would never fire and the
loop would hang. Covered for a multishot recvmsg and for a one-shot recv.

Both tests depend on the kernel handing B the lowest free number, which
Linux always does; if it does not, the test prints SKIP and returns.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true

from boucle.drivers.epoll_completion import EpollCompletionDriver
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.socle.linux.raw import iovec, msghdr, ECANCELED, F_GETFD, FD_CLOEXEC

comptime BUF_COUNT = 4
comptime BUF_SIZE = 256
comptime NAME_CAP = 28
comptime GROUP = 5


struct Tracker:
    """Records every completion fired on one Completion."""

    var count: Int
    var results: Array[Int, 16]
    var flags: Array[UInt32, 16]

    def __init__(out self):
        """Construct an empty tracker."""
        self.count = 0
        self.results = Array[Int, 16](fill=0)
        self.flags = Array[UInt32, 16](fill=UInt32(0))

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """Store result and flags at the next index."""
        var self_ptr = Pointer[Tracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        var i = self_ptr[].count
        if i < 16:
            self_ptr[].results[i] = result
            self_ptr[].flags[i] = flags
        self_ptr[].count += 1


def _completion(ref tracker: Tracker) -> Completion:
    """Wire a Completion onto `tracker`."""
    return Completion(
        invoke=Tracker.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=tracker))
        ),
    )


def _ptr[T: AnyType](ref value: T) -> Pointer[T, MutUntrackedOrigin]:
    """Untracked pointer to a caller-owned value."""
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=value))
    )


def _send(ref sender: Socket, ref to: SocketAddrV4) raises:
    """Send the 4-byte datagram "ping" to `to`."""
    var payload = List[UInt8](length=4, fill=0)
    payload[0] = UInt8(ord("p"))
    payload[1] = UInt8(ord("i"))
    payload[2] = UInt8(ord("n"))
    payload[3] = UInt8(ord("g"))
    assert_equal(sender.send_to(Span(payload), to), 4)


def _tick_until(
    mut driver: EpollCompletionDriver, ref tracker: Tracker, count: Int, what: String
) raises:
    """Tick (blocking, one second at most each) until `tracker.count >= count`.

    Bounded at ten ticks so a completion the driver lost fails the test
    with `what` instead of hanging it. The count is read through an
    untracked pointer because the driver writes it from a callback the
    compiler cannot see.
    """
    var seen = Pointer[Tracker, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var ticks = 0
    while seen[].count < count:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 10, what)


def _bound_udp() raises -> Socket:
    """Create a UDP socket bound to an ephemeral loopback port."""
    var s = Socket.udp_v4()
    s.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    return s^


def test_multishot_on_closed_socket_does_not_detach_reused_fd() raises:
    """Cancelling a multishot armed on a closed fd leaves a one-shot on the reused number armed."""
    var driver = EpollCompletionDriver(capacity=8)
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](BUF_COUNT * BUF_SIZE))
    )
    for i in range(BUF_COUNT * BUF_SIZE):
        mem[unsafe_offset=i] = UInt8(0)
    driver.register_buffer_group(mem, UInt32(BUF_SIZE), BUF_COUNT, UInt16(GROUP))

    var a = _bound_udp()
    var reused = Int(a.raw())
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(NAME_CAP)
    var a_tracker = Tracker()
    var a_cmp = _completion(a_tracker)
    driver.multishot_recvmsg(
        a.raw(), _ptr(tmpl).unsafe_bitcast[NoneType](), UInt16(GROUP), _ptr(a_cmp)
    )
    a.close()

    var b = _bound_udp()
    if Int(b.raw()) != reused:
        print("SKIP: kernel did not reuse fd", reused, "for the new socket")
        driver.unregister_buffer_group(UInt16(GROUP))
        mem.unsafe_free()
        return
    var to = b.local_addr_v4()

    var inbox = List[UInt8](length=16, fill=0)
    var iov = iovec()
    iov.iov_base = UInt64(Int(inbox.unsafe_ptr()))
    iov.iov_len = UInt64(16)
    var hdr = msghdr()
    hdr.msg_iov = UInt64(Int(Pointer(to=iov)))
    hdr.msg_iovlen = UInt64(1)
    var b_tracker = Tracker()
    var b_cmp = _completion(b_tracker)
    driver.recvmsg(b.raw(), _ptr(hdr).unsafe_bitcast[NoneType](), _ptr(b_cmp))

    # The dropped stream's deferred cancel.
    var cancel_tracker = Tracker()
    var cancel_cmp = _completion(cancel_tracker)
    driver.cancel(_ptr(a_cmp), _ptr(cancel_cmp))
    assert_equal(driver.tick(wait=False), 2)
    assert_equal(a_tracker.results[0], -Int(ECANCELED))
    assert_equal(cancel_tracker.results[0], 0)

    var sender = Socket.udp_v4()
    _send(sender, to)
    _tick_until(driver, b_tracker, 1, "the op on the reused fd never completed")
    assert_equal(b_tracker.results[0], 4)
    assert_equal(Int(inbox[0]), ord("p"))

    driver.unregister_buffer_group(UInt16(GROUP))
    mem.unsafe_free()
    b.close()
    sender.close()
    _ = a_cmp
    _ = b_cmp
    _ = cancel_cmp
    _ = tmpl
    _ = hdr
    _ = iov
    _ = inbox


def test_recv_on_closed_socket_does_not_detach_reused_fd() raises:
    """Cancelling a one-shot recv armed on a closed fd leaves a recv on the reused number armed."""
    var driver = EpollCompletionDriver(capacity=8)

    var a = _bound_udp()
    var reused = Int(a.raw())
    var a_buf = List[UInt8](length=16, fill=0)
    var a_tracker = Tracker()
    var a_cmp = _completion(a_tracker)
    driver.recv(
        a.raw(),
        Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(a_buf.unsafe_ptr())
        ),
        UInt32(16),
        _ptr(a_cmp),
    )
    a.close()

    var b = _bound_udp()
    if Int(b.raw()) != reused:
        print("SKIP: kernel did not reuse fd", reused, "for the new socket")
        return
    var to = b.local_addr_v4()
    var b_buf = List[UInt8](length=16, fill=0)
    var b_tracker = Tracker()
    var b_cmp = _completion(b_tracker)
    driver.recv(
        b.raw(),
        Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(b_buf.unsafe_ptr())
        ),
        UInt32(16),
        _ptr(b_cmp),
    )

    var cancel_tracker = Tracker()
    var cancel_cmp = _completion(cancel_tracker)
    driver.cancel(_ptr(a_cmp), _ptr(cancel_cmp))
    assert_equal(driver.tick(wait=False), 2)
    assert_equal(a_tracker.results[0], -Int(ECANCELED))
    assert_equal(cancel_tracker.results[0], 0)

    var sender = Socket.udp_v4()
    _send(sender, to)
    _tick_until(driver, b_tracker, 1, "the recv on the reused fd never completed")
    assert_equal(b_tracker.results[0], 4)
    assert_equal(Int(b_buf[3]), ord("g"))

    b.close()
    sender.close()
    _ = a_cmp
    _ = b_cmp
    _ = cancel_cmp
    _ = a_buf
    _ = b_buf


def _fd_flags(fd: Int32) -> Int32:
    """Read descriptor flags via fcntl(fd, F_GETFD, 0).

    Args:
        fd: The descriptor to query.

    Returns:
        The FD_* flags, or -1 on failure.
    """
    return external_call["fcntl", Int32](fd, Int32(F_GETFD), Int32(0))


def test_per_op_dup_is_close_on_exec() raises:
    """The private dup an armed op registers carries FD_CLOEXEC like every other fd."""
    var driver = EpollCompletionDriver(capacity=8)
    var a = _bound_udp()
    var inbox = List[UInt8](length=16, fill=0)
    var iov = iovec()
    iov.iov_base = UInt64(Int(inbox.unsafe_ptr()))
    iov.iov_len = UInt64(16)
    var hdr = msghdr()
    hdr.msg_iov = UInt64(Int(Pointer(to=iov)))
    hdr.msg_iovlen = UInt64(1)
    var tracker = Tracker()
    var cmp = _completion(tracker)
    driver.recvmsg(a.raw(), _ptr(hdr).unsafe_bitcast[NoneType](), _ptr(cmp))

    var seen = 0
    for i in range(driver._state[].pool._capacity):
        var op = driver._state[].pool._slots.unsafe_offset(i)
        if not op[].active or op[].dup_fd == Int32(-1):
            continue
        seen += 1
        assert_true(op[].dup_fd != a.raw(), "the op runs on a private dup")
        var flags = _fd_flags(op[].dup_fd)
        assert_true(flags >= 0, "F_GETFD on the dup")
        assert_true(
            (Int(flags) & FD_CLOEXEC) != 0, "the per-op dup is close-on-exec"
        )
    assert_equal(seen, 1, "exactly one armed op holds a dup")

    var cancel_tracker = Tracker()
    var cancel_cmp = _completion(cancel_tracker)
    driver.cancel(_ptr(cmp), _ptr(cancel_cmp))
    assert_equal(driver.tick(wait=False), 2)
    a.close()
    _ = cmp
    _ = cancel_cmp
    _ = hdr
    _ = iov
    _ = inbox


def main() raises:
    test_multishot_on_closed_socket_does_not_detach_reused_fd()
    test_recv_on_closed_socket_does_not_detach_reused_fd()
    test_per_op_dup_is_close_on_exec()
    print("PASS: test_epoll_fd_reuse.mojo")
