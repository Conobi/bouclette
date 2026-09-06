"""Tests for EpollCompletionDriver.

Verifies the epoll-based completion emulation: nop (deferred-ready
queue), timeout (userspace timer heap with -ETIME result), a one-shot
recv that ends when its socket is shut down for reading, and one that
stays armed when epoll reports a bare error bit the socket has already
consumed.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true
from std.time import sleep

from boucle.proactor.completion import Completion
from boucle.drivers.epoll_completion import EpollCompletionDriver
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Shutdown
from boucle.error import IOError
from boucle.net.socket import Socket
from boucle.socle.linux.raw import (
    syscall,
    __kernel_timespec,
    __NR_setsockopt,
    EAGAIN,
    ECONNREFUSED,
    ECONNRESET,
    ETIME,
    SOL_IP,
)

# `IP_RECVERR` is not part of the portable option set: it is set through a
# raw setsockopt here to reproduce a socket whose error queue stays
# non-empty after its pending error was consumed.
comptime IP_RECVERR = 11


# ── Shared callback tracker ──────────────────────────────────────────────────


struct ResultSlot:
    """Records a single completion result and whether it fired."""

    var result: Int
    var fired: Bool

    def __init__(out self):
        """Construct an unfired slot."""
        self.result = 0
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the result."""
        var self_ptr = Pointer[ResultSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


# ── Tests ────────────────────────────────────────────────────────────────────


def test_nop_fires_with_zero() raises:
    """Nop enqueues to the ready queue; tick dispatches with result 0."""
    var driver = EpollCompletionDriver(capacity=8)
    var slot = ResultSlot()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var cmp = Completion(invoke=ResultSlot.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    driver.nop(cmp_ptr)
    var dispatched = driver.tick(wait=False)

    assert_true(slot.fired, "nop callback did not fire")
    assert_equal(Int(slot.result), 0)
    assert_equal(dispatched, 1)

    _ = cmp


def test_timeout_fires_with_etime() raises:
    """Timeout fires with -ETIME after the deadline passes."""
    var driver = EpollCompletionDriver(capacity=8)
    var slot = ResultSlot()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var cmp = Completion(invoke=ResultSlot.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    # 50ms timeout.
    var ts = __kernel_timespec(0, 50_000_000)
    var ts_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=ts))
    )
    driver.timeout(ts_ptr, cmp_ptr)

    # Tick with wait=True should block until the timer fires.
    var ticks = 0
    while not slot.fired:
        _ = driver.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for timeout completion"

    assert_true(slot.fired, "timeout callback did not fire")
    assert_equal(Int(slot.result), -Int(ETIME))

    _ = cmp
    _ = ts


def test_recv_ends_on_read_shutdown() raises:
    """A one-shot recv on a read-shut UDP socket ends with -ECONNRESET.

    The socket is reported readable with EPOLLRDHUP while recv only
    ever returns EAGAIN; the op fires its terminal on that wake instead
    of staying armed forever.
    """
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.connect(receiver.local_addr_v4())
    var slot = ResultSlot()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var cmp = Completion(invoke=ResultSlot.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )
    var buf = List[UInt8](length=16, fill=0)
    var slots_before = driver._state[].pool.free_count()
    driver.recv(
        receiver.raw(),
        Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(buf.unsafe_ptr())
        ),
        UInt32(16),
        cmp_ptr,
    )
    receiver.shutdown(Shutdown.RD)

    var ticks = 0
    while not slot.fired:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 50, "the read shutdown never ended the recv")
    assert_equal(Int(slot.result), -Int(ECONNRESET))
    assert_equal(driver._state[].pool.free_count(), slots_before, "slot freed")
    assert_equal(driver.tick(wait=False), 0, "nothing left to fire")

    receiver.close()
    _ = cmp
    _ = buf


def _closed_loopback_port() raises -> SocketAddrV4:
    """Return a loopback UDP address nothing listens on.

    A socket is bound to an ephemeral port and closed again; a datagram
    sent there draws an ICMP port-unreachable.
    """
    var probe = Socket.udp_v4()
    probe.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var addr = probe.local_addr_v4()
    probe.close()
    return addr


def _recv_errno(ref socket: Socket, mut inbox: List[UInt8]) raises IOError -> Int:
    """Return the positive errno a non-blocking `recv` fails with, or 0 on data."""
    try:
        _ = socket.recv(Span(inbox))
        return 0
    except e:
        return e.errno_value()


def _consume_refusal(ref socket: Socket) raises:
    """Wait for the ICMP error to land and consume it through a plain `recv`.

    The refusal is reported once by the socket call; with `IP_RECVERR` set
    the queued error record stays behind and keeps EPOLLERR asserted.
    """
    var inbox = List[UInt8](length=16, fill=0)
    var tries = 0
    while True:
        var errno = _recv_errno(socket, inbox)
        if errno == ECONNREFUSED:
            return
        assert_equal(errno, EAGAIN, "recv failed with an unexpected errno")
        tries += 1
        assert_true(tries < 500, "the ICMP port-unreachable never arrived")
        sleep(0.001)


def test_recv_stays_armed_on_consumed_error() raises:
    """A bare EPOLLERR with a clean SO_ERROR leaves a one-shot recv armed.

    An `IP_RECVERR` socket whose error queue holds a record has EPOLLERR
    asserted even after the pending error was consumed, so the very first
    wake after arming carries EPOLLERR while recv reports EAGAIN. That
    wake must not end the op: a datagram sent afterwards still wakes it
    (edge-triggered, so nothing spins) and completes it with the
    datagram's length.
    """
    var driver = EpollCompletionDriver(capacity=8)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var on = Int32(1)
    var set_res = syscall[__NR_setsockopt, Scalar[DType.int64]](
        receiver.raw(),
        Int32(SOL_IP),
        Int32(IP_RECVERR),
        Pointer(to=on),
        UInt(4),
    )
    assert_equal(Int(set_res), 0, "IP_RECVERR set")
    var dead = _closed_loopback_port()
    receiver.connect(dead)
    var ping = List[UInt8](length=4, fill=UInt8(1))
    assert_equal(receiver.send(Span(ping)), 4)
    _consume_refusal(receiver)

    # The port the refusal came from is free again: a sender bound there
    # is the peer the connected receiver accepts datagrams from.
    var sender = Socket.udp_v4()
    sender.set_reuse_addr()
    sender.bind(dead)

    var slot = ResultSlot()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var cmp = Completion(invoke=ResultSlot.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )
    var buf = List[UInt8](length=16, fill=0)
    var slots_before = driver._state[].pool.free_count()
    driver.recv(
        receiver.raw(),
        Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(buf.unsafe_ptr())
        ),
        UInt32(16),
        cmp_ptr,
    )
    # The registration reports EPOLLERR at once; recv gives EAGAIN.
    assert_equal(driver.tick(wait=False), 0, "the bare error wake fired nothing")
    assert_true(not slot.fired, "the op is still armed")
    assert_equal(
        driver._state[].pool.free_count(), slots_before - 1, "slot still held"
    )

    var payload = List[UInt8](length=4, fill=0)
    payload[0] = UInt8(ord("D"))
    payload[1] = UInt8(ord("a"))
    payload[2] = UInt8(ord("t"))
    payload[3] = UInt8(ord("a"))
    assert_equal(sender.send_to(Span(payload), receiver.local_addr_v4()), 4)
    var ticks = 0
    while not slot.fired:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 50, "the datagram never completed the recv")
    assert_equal(Int(slot.result), 4, "the recv completed with the datagram")
    assert_equal(Int(buf[0]), ord("D"))
    assert_equal(Int(buf[3]), ord("a"))
    assert_equal(driver._state[].pool.free_count(), slots_before, "slot freed")

    receiver.close()
    sender.close()
    _ = cmp
    _ = buf


def main() raises:
    test_nop_fires_with_zero()
    test_timeout_fires_with_etime()
    test_recv_ends_on_read_shutdown()
    test_recv_stays_armed_on_consumed_error()
    print("All epoll completion driver tests passed.")
