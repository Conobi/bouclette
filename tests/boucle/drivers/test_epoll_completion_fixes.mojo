"""Regression tests for EpollCompletionDriver correctness bugs.

Each test reproduces one bug in the epoll completion emulation and
stays red until that bug is fixed. All tests construct
EpollCompletionDriver directly so they never fall through to io_uring.

Run a single test by passing its name as the first argument:

    mojo run -I . -D ASSERT=all tests/boucle/drivers/test_epoll_completion_fixes.mojo <test_name>
"""

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.sys import argv
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.proactor.completion import Completion
from boucle.drivers.epoll_completion import (
    EpollCompletionDriver,
    _epoll_wait_timeout_ms,
)
from boucle.handle import RawHandle
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.options import Backlog
from boucle.socle.linux.raw import (
    syscall,
    sockaddr_in,
    __NR_write,
    __NR_fcntl,
    __NR_connect,
    F_GETFL,
    O_NONBLOCK,
    ECANCELED,
    ENOENT,
    EAGAIN,
)
from boucle.socle.ptr import null_ptr


# Size of the epoll_wait event array. Deliberately small so that tests
# with more in-flight ops than this prove the two are independent.
comptime MAX_EVENTS = 8

# In-flight ops for the pool growth test: well past the initial pool
# capacity (64) and MAX_EVENTS, yet only 402 fds (ulimit -n is >= 1024).
comptime IN_FLIGHT_BEYOND_POOL = 200


# ── Callback contexts ────────────────────────────────────────────────────────


struct FireCounter:
    """Shared context counting fires across many completions.

    Every completion in the pool growth test points at the same
    counter, so no per-op context struct has to be kept alive.
    """

    var count: Int
    var unexpected_results: Int

    def __init__(out self):
        """Construct a counter with no fires recorded."""
        self.count = 0
        self.unexpected_results = 0

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Count the fire; flag any result other than the 1 byte written."""
        var self_ptr = Pointer[FireCounter, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].count += 1
        if result != 1:
            self_ptr[].unexpected_results += 1


struct IOSlot:
    """Records every fire of one completion: last result, flags, count."""

    var result: Int
    var flags: UInt32
    var fired: Bool
    var fire_count: Int

    def __init__(out self):
        """Construct an unfired slot."""
        self.result = 0
        self.flags = UInt32(0)
        self.fired = False
        self.fire_count = 0

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records result, flags and the fire count."""
        var self_ptr = Pointer[IOSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].flags = flags
        self_ptr[].fired = True
        self_ptr[].fire_count += 1


struct SubmitOnFire:
    """Callback context whose callback submits a new op on the driver.

    On its FIRST fire the callback either submits a nop for `next`
    (cancel_target is null) or submits a cancel of `cancel_target`
    whose own completion is `next`. Later fires only record.
    """

    var driver: Pointer[EpollCompletionDriver, MutUntrackedOrigin]
    var next: Pointer[Completion, MutUntrackedOrigin]
    var cancel_target: Pointer[Completion, MutUntrackedOrigin]
    var result: Int
    var fire_count: Int
    var submit_failed: Bool

    def __init__(
        out self,
        driver: Pointer[EpollCompletionDriver, MutUntrackedOrigin],
        next: Pointer[Completion, MutUntrackedOrigin],
    ):
        """Construct a context that submits a nop for `next` when fired."""
        self.driver = driver
        self.next = next
        self.cancel_target = null_ptr[Completion, MutUntrackedOrigin]()
        self.result = 0
        self.fire_count = 0
        self.submit_failed = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Record the result, then submit nop or cancel on first fire."""
        var self_ptr = Pointer[SubmitOnFire, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fire_count += 1
        if self_ptr[].fire_count > 1:
            return
        try:
            if Int(self_ptr[].cancel_target) == 0:
                self_ptr[].driver[].nop(self_ptr[].next)
            else:
                self_ptr[].driver[].cancel(
                    self_ptr[].cancel_target, self_ptr[].next
                )
        except:
            self_ptr[].submit_failed = True


# ── Helpers ──────────────────────────────────────────────────────────────────


def _make_socketpair() raises -> Array[Int32, 2]:
    """Create an AF_UNIX SOCK_STREAM socketpair."""
    var sv = Array[Int32, 2](fill=0)
    var res = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1),  # SOCK_STREAM
        0,
        Pointer(to=sv).unsafe_bitcast[Int32](),
    )
    assert_equal(Int(res), 0, "socketpair failed")
    return sv^


def _completion_ptr(
    ref cmp: Completion,
) -> Pointer[Completion, MutUntrackedOrigin]:
    """Erase the origin of a Completion reference for the driver API."""
    return Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )


def _slot_completion(ref slot: IOSlot) -> Completion:
    """Create a Completion wired to an IOSlot."""
    return Completion(
        invoke=IOSlot.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=slot))
        ),
    )


def _counter_completion(ref counter: FireCounter) -> Completion:
    """Create a Completion wired to a shared FireCounter."""
    return Completion(
        invoke=FireCounter.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=counter))
        ),
    )


def _submit_on_fire_completion(ref ctx: SubmitOnFire) -> Completion:
    """Create a Completion wired to a SubmitOnFire context."""
    return Completion(
        invoke=SubmitOnFire.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=ctx))
        ),
    )


def _driver_ptr(
    ref driver: EpollCompletionDriver,
) -> Pointer[EpollCompletionDriver, MutUntrackedOrigin]:
    """Erase the origin of a driver reference so callbacks can submit."""
    return Pointer[EpollCompletionDriver, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=driver))
    )


def _write_one_byte(fd: RawHandle) raises:
    """Write a single byte to fd so a pending recv becomes readable."""
    var byte = UInt8(0xAB)
    var res = syscall[__NR_write, Scalar[DType.int64]](
        fd, Pointer(to=byte), UInt64(1)
    )
    assert_equal(Int(res), 1, "write failed")


def _loopback_listener_port(ref server: Socket) raises -> UInt16:
    """Return the host-order port a loopback listener was bound to."""
    var bound = sockaddr_in()
    var bound_len = Int32(16)
    var gs = external_call["getsockname", Int32](
        server.raw(),
        Pointer(to=bound).unsafe_bitcast[Int8](),
        Pointer(to=bound_len).unsafe_bitcast[Int8](),
    )
    assert_equal(Int(gs), 0, "getsockname failed")
    var be_port: UInt16 = bound.sin_port
    return ((be_port << 8) | (be_port >> 8)) & UInt16(0xFFFF)


def _fd_flags(fd: RawHandle) raises -> Int64:
    """Return the F_GETFL flags of fd."""
    var res = syscall[__NR_fcntl, Scalar[DType.int64]](
        fd, Int32(F_GETFL), Int32(0)
    )
    assert_true(res >= 0, "fcntl(F_GETFL) failed")
    return Int64(res)


# ── Bug 1: ready-queue drain drops entries appended by callbacks ─────────────


def test_nop_submitted_from_callback_fires_on_next_tick() raises:
    """A nop submitted from inside a nop callback must not be lost.

    The drain loop fixed its bound before firing, then cleared the
    whole queue -- discarding whatever the callbacks appended.
    """
    var driver = EpollCompletionDriver(max_events=MAX_EVENTS)

    var second = IOSlot()
    var second_cmp = _slot_completion(second)
    var first = SubmitOnFire(_driver_ptr(driver), _completion_ptr(second_cmp))
    var first_cmp = _submit_on_fire_completion(first)

    driver.nop(_completion_ptr(first_cmp))
    var dispatched = driver.tick(wait=False)
    dispatched += driver.tick(wait=False)

    assert_equal(first.fire_count, 1, "first nop must fire exactly once")
    assert_true(not first.submit_failed, "nop from callback raised")
    assert_true(second.fired, "nop submitted from callback was dropped")
    assert_equal(second.fire_count, 1)
    assert_equal(dispatched, 2, "both nops must be counted as dispatched")
    assert_equal(len(driver._state[].ready), 0, "ready queue must be empty")

    _ = first_cmp
    _ = second_cmp


# ── Bug 2: slot freed after fire() -> cancel-from-callback double-frees ──────


def test_callback_cancelling_its_own_completion_does_not_double_free() raises:
    """A recv callback that cancels its own completion must see ENOENT.

    The slot was still active while the callback ran, so cancel
    found it, freed it and re-enqueued the target; _dispatch_op then
    freed the slot a second time and the target fired twice.
    """
    var sv = _make_socketpair()
    var fd_a: RawHandle = sv[0]
    var fd_b: RawHandle = sv[1]
    var driver = EpollCompletionDriver(max_events=MAX_EVENTS)

    var cancel_slot = IOSlot()
    var cancel_cmp = _slot_completion(cancel_slot)
    var recv = SubmitOnFire(_driver_ptr(driver), _completion_ptr(cancel_cmp))
    var recv_cmp = _submit_on_fire_completion(recv)
    recv.cancel_target = _completion_ptr(recv_cmp)

    var buf = List[UInt8](length=16, fill=0)
    var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    driver.recv(fd_a, buf_ptr, UInt32(16), _completion_ptr(recv_cmp))
    _write_one_byte(fd_b)

    _ = driver.tick(wait=True)
    _ = driver.tick(wait=False)
    _ = driver.tick(wait=False)

    assert_equal(recv.fire_count, 1, "recv must fire exactly once")
    assert_equal(recv.result, 1, "recv must report the byte received")
    assert_true(not recv.submit_failed, "cancel from callback raised")
    assert_true(cancel_slot.fired, "cancel completion did not fire")
    assert_equal(
        cancel_slot.result,
        -Int(ENOENT),
        "cancel of a completed op must report -ENOENT",
    )

    _ = external_call["close", Int32](fd_a)
    _ = external_call["close", Int32](fd_b)
    _ = buf
    _ = recv_cmp
    _ = cancel_cmp


# ── Bug 3: stale slot dispatched from the same epoll batch ───────────────────


def test_op_cancelled_by_earlier_callback_in_same_batch_fires_once() raises:
    """Two readable recvs; the first callback cancels the second.

    The second op's event is already in the epoll batch. Its slot was
    freed by the cancel, yet the loop still dispatched it: the stale
    op performed the recv, fired with data, and freed the slot again.
    The cancelled op must fire exactly once, with -ECANCELED.
    """
    var sv_a = _make_socketpair()
    var sv_b = _make_socketpair()
    var driver = EpollCompletionDriver(max_events=MAX_EVENTS)

    var cancel_a_slot = IOSlot()
    var cancel_a_cmp = _slot_completion(cancel_a_slot)
    var cancel_b_slot = IOSlot()
    var cancel_b_cmp = _slot_completion(cancel_b_slot)

    var recv_a = SubmitOnFire(
        _driver_ptr(driver), _completion_ptr(cancel_a_cmp)
    )
    var recv_a_cmp = _submit_on_fire_completion(recv_a)
    var recv_b = SubmitOnFire(
        _driver_ptr(driver), _completion_ptr(cancel_b_cmp)
    )
    var recv_b_cmp = _submit_on_fire_completion(recv_b)
    # Whichever fires first cancels the other.
    recv_a.cancel_target = _completion_ptr(recv_b_cmp)
    recv_b.cancel_target = _completion_ptr(recv_a_cmp)

    var buf_a = List[UInt8](length=16, fill=0)
    var buf_b = List[UInt8](length=16, fill=0)
    driver.recv(
        sv_a[0],
        Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(buf_a.unsafe_ptr())
        ),
        UInt32(16),
        _completion_ptr(recv_a_cmp),
    )
    driver.recv(
        sv_b[0],
        Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(buf_b.unsafe_ptr())
        ),
        UInt32(16),
        _completion_ptr(recv_b_cmp),
    )
    _write_one_byte(sv_a[1])
    _write_one_byte(sv_b[1])

    _ = driver.tick(wait=True)
    _ = driver.tick(wait=False)
    _ = driver.tick(wait=False)

    assert_equal(recv_a.fire_count, 1, "recv A must fire exactly once")
    assert_equal(recv_b.fire_count, 1, "recv B must fire exactly once")
    var completed_then_cancelled = (
        recv_a.result == 1 and recv_b.result == -Int(ECANCELED)
    )
    var cancelled_then_completed = (
        recv_b.result == 1 and recv_a.result == -Int(ECANCELED)
    )
    assert_true(
        completed_then_cancelled or cancelled_then_completed,
        "one recv must complete with 1 byte and the other with -ECANCELED",
    )

    for i in range(2):
        _ = external_call["close", Int32](sv_a[i])
        _ = external_call["close", Int32](sv_b[i])
    _ = buf_a
    _ = buf_b
    _ = recv_a_cmp
    _ = recv_b_cmp
    _ = cancel_a_cmp
    _ = cancel_b_cmp


# ── Bug 4: ACCEPT has no EAGAIN retry ────────────────────────────────────────


def test_second_accept_on_same_listener_stays_pending_on_eagain() raises:
    """Two accepts on one listener, one client: exactly one may fire.

    Both registrations wake on the incoming connection. The second
    accept4 returns -EAGAIN, which was delivered to the user instead
    of leaving the op pending like recv/send do.
    """
    var server = Socket.tcp_v4()
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)
    var port = _loopback_listener_port(server)
    var target_stor = SocketAddrV4(127, 0, 0, 1, port=port).addr_stor()

    var driver = EpollCompletionDriver(max_events=MAX_EVENTS)

    var accept_1 = IOSlot()
    var accept_1_cmp = _slot_completion(accept_1)
    var accept_2 = IOSlot()
    var accept_2_cmp = _slot_completion(accept_2)
    var connect_slot = IOSlot()
    var connect_cmp = _slot_completion(connect_slot)

    driver.accept(server.raw(), _completion_ptr(accept_1_cmp))
    driver.accept(server.raw(), _completion_ptr(accept_2_cmp))

    var client = Socket.tcp_v4()
    driver.connect(
        client.raw(),
        target_stor.addr_unsafe_ptr(),
        UInt64(SocketAddrStorV4.ADDR_LEN),
        _completion_ptr(connect_cmp),
    )

    var ticks = 0
    while not connect_slot.fired or not (accept_1.fired or accept_2.fired):
        _ = driver.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for accept/connect completion"
    _ = driver.tick(wait=False)
    _ = driver.tick(wait=False)

    assert_equal(connect_slot.result, 0, "connect must succeed")
    assert_true(
        accept_1.fired != accept_2.fired,
        "exactly one accept must fire for a single connection",
    )
    var accepted_fd = accept_1.result if accept_1.fired else accept_2.result
    assert_true(accepted_fd >= 0, "accepted fd must be >= 0")
    assert_true(
        accept_1.result != -Int(EAGAIN) and accept_2.result != -Int(EAGAIN),
        "-EAGAIN must never be delivered to the user",
    )

    _ = external_call["close", Int32](Int32(accepted_fd))
    _ = accept_1_cmp
    _ = accept_2_cmp
    _ = connect_cmp
    _ = target_stor
    _ = client^
    _ = server^


# ── Bug 5: _register_op failure leaks the slot ───────────────────────────────


def test_failed_epoll_registration_releases_pool_slot() raises:
    """A failed epoll_ctl(ADD) (EPERM on /dev/null) must free the slot.

    The exception propagated while the freshly allocated slot stayed
    active, permanently shrinking the pool by one per failed submit.
    """
    var driver = EpollCompletionDriver(max_events=MAX_EVENTS)

    # "/dev/null\0" as a NUL-terminated byte array.
    var path = Array[UInt8, 10](fill=0)
    var text = "/dev/null"
    for i in range(9):
        path[i] = text.as_bytes()[i]
    var dev_null = external_call["open", Int32](
        Pointer(to=path).unsafe_bitcast[UInt8](), Int32(0)
    )
    assert_true(Int(dev_null) >= 0, "open(/dev/null) failed")

    var slot = IOSlot()
    var cmp = _slot_completion(slot)
    var buf = List[UInt8](length=16, fill=0)
    var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )

    var raised = False
    try:
        driver.recv(dev_null, buf_ptr, UInt32(16), _completion_ptr(cmp))
    except:
        raised = True

    assert_true(raised, "recv on /dev/null must raise")
    assert_true(not slot.fired, "no completion may fire for a failed submit")

    _ = external_call["close", Int32](dev_null)
    _ = buf
    _ = path
    _ = cmp


# ── Bug 6: connect blocks on a blocking socket ────────────────────────


def test_connect_on_blocking_socket_does_not_block_submit() raises:
    """Connecting a blocking socket must not stall connect.

    The listener's accept queue is filled so further SYNs are dropped;
    a blocking connect(2) would then stall inside connect until
    the SYN retries time out (minutes). io_uring connects asynchronously
    regardless of O_NONBLOCK, so the epoll driver must too -- and must
    restore the socket's original flags afterwards.
    """
    var server = Socket.tcp_v4()
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog(1))
    var port = _loopback_listener_port(server)
    var target_stor = SocketAddrV4(127, 0, 0, 1, port=port).addr_stor()
    var addr_ptr = target_stor.addr_unsafe_ptr()
    var addr_len = UInt64(SocketAddrStorV4.ADDR_LEN)

    # Fill the accept queue (backlog 1 admits two established
    # connections); the remaining SYNs are dropped and stay SYN_SENT.
    var fillers = List[Socket]()
    for _ in range(6):
        var filler = Socket.tcp_v4()
        _ = syscall[__NR_connect, Scalar[DType.int64]](
            filler.raw(), addr_ptr, addr_len
        )
        fillers.append(filler^)

    var driver = EpollCompletionDriver(max_events=MAX_EVENTS)
    var connect_slot = IOSlot()
    var connect_cmp = _slot_completion(connect_slot)
    var cancel_slot = IOSlot()
    var cancel_cmp = _slot_completion(cancel_slot)

    var client = Socket.tcp_v4()
    client.set_blocking(True)
    var flags_before = _fd_flags(client.raw())
    assert_true(
        (flags_before & Int64(O_NONBLOCK)) == 0, "socket must be blocking"
    )

    var start_ns = perf_counter_ns()
    driver.connect(
        client.raw(), addr_ptr, addr_len, _completion_ptr(connect_cmp)
    )
    var elapsed_ms = (perf_counter_ns() - start_ns) // 1_000_000

    assert_true(
        elapsed_ms < 1000,
        "connect blocked for " + String(elapsed_ms) + "ms",
    )
    assert_equal(
        _fd_flags(client.raw()),
        flags_before,
        "connect must restore the socket's original flags",
    )
    assert_true(not connect_slot.fired, "no callback may fire during submit")

    # Tear down the pending connect so the driver holds no dangling op.
    driver.cancel(
        _completion_ptr(connect_cmp), _completion_ptr(cancel_cmp)
    )
    _ = driver.tick(wait=False)
    assert_true(connect_slot.fired, "connect must fire after cancel")
    assert_true(
        connect_slot.result == -Int(ECANCELED) or connect_slot.result == 0,
        "connect must report -ECANCELED (pending) or 0 (raced to success)",
    )

    _ = connect_cmp
    _ = cancel_cmp
    _ = target_stor
    _ = client^
    _ = fillers^
    _ = server^


# ── Bug 7: cancel of an unknown target must report -ENOENT ───────────────────


def test_cancel_of_unknown_target_reports_enoent() raises:
    """Cancelling a completion that was never submitted yields -ENOENT.

    io_uring reports -ENOENT when the target is not found; the epoll
    driver reported 0 as if a cancellation had happened.
    """
    var driver = EpollCompletionDriver(max_events=MAX_EVENTS)

    var never_submitted = Completion()
    var cancel_slot = IOSlot()
    var cancel_cmp = _slot_completion(cancel_slot)

    driver.cancel(
        _completion_ptr(never_submitted), _completion_ptr(cancel_cmp)
    )
    var dispatched = driver.tick(wait=False)

    assert_equal(dispatched, 1)
    assert_true(cancel_slot.fired, "cancel completion did not fire")
    assert_equal(
        cancel_slot.result,
        -Int(ENOENT),
        "cancel of an unknown target must report -ENOENT",
    )

    _ = never_submitted
    _ = cancel_cmp


# ── Bug 8: op pool sized from max_events caps in-flight ops ──────────────────


def test_more_in_flight_ops_than_max_events_all_complete() raises:
    """200 recvs in flight on a max_events=8 driver must all complete.

    The op pool was sized from max_events and recv() raised "op pool
    exhausted" once every slot was taken. io_uring has no such limit
    (the kernel holds in-flight ops), so the pool must grow on demand
    and max_events must only size the epoll_wait event array. The
    extra submit past the 200 also proves growth is not a one-off.
    """
    var driver = EpollCompletionDriver(max_events=MAX_EVENTS)
    var total = IN_FLIGHT_BEYOND_POOL + 1
    var counter = FireCounter()

    var completions = unsafe_alloc[Completion](total)
    var buffers = List[UInt8](length=total * 16, fill=0)
    var fds = List[Int32](capacity=total * 2)
    for i in range(total):
        var sv = _make_socketpair()
        fds.append(sv[0])
        fds.append(sv[1])
        completions.unsafe_offset(i).unsafe_write(_counter_completion(counter))

    for i in range(IN_FLIGHT_BEYOND_POOL):
        driver.recv(
            fds[2 * i],
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(buffers.unsafe_ptr()) + i * 16
            ),
            UInt32(16),
            completions.unsafe_offset(i),
        )

    var last = IN_FLIGHT_BEYOND_POOL
    var raised = False
    try:
        driver.recv(
            fds[2 * last],
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(buffers.unsafe_ptr()) + last * 16
            ),
            UInt32(16),
            completions.unsafe_offset(last),
        )
    except:
        raised = True
    assert_true(not raised, "submit past the initial pool capacity raised")

    for i in range(total):
        _write_one_byte(fds[2 * i + 1])

    var ticks = 0
    while counter.count < total:
        _ = driver.tick(wait=True)
        ticks += 1
        if ticks > 1000:
            raise "timed out: only " + String(counter.count) + " completions"

    assert_equal(counter.count, total, "every in-flight recv must fire once")
    assert_equal(counter.unexpected_results, 0, "every recv must read 1 byte")
    assert_equal(
        driver._state[].pool.free_count(),
        driver._state[].pool.capacity(),
        "every slot must be free once every op has completed",
    )

    for i in range(len(fds)):
        _ = external_call["close", Int32](fds[i])
    completions.unsafe_free()
    _ = buffers


# ── Bug 9: far-future timer truncates to a negative epoll timeout ────────────


def test_far_future_timer_does_not_block_forever() raises:
    """A deadline 40 days out must clamp to Int32.MAX, not go negative.

    The millisecond count was cast straight to Int32; past ~24.8 days
    it wrapped negative, which epoll_wait reads as "block forever".
    """
    var forty_days_ns = Int64(40) * 24 * 60 * 60 * 1_000_000_000
    var timeout = _epoll_wait_timeout_ms(
        wait=True, has_deadline=True, remaining_ns=forty_days_ns
    )
    assert_true(timeout > 0, "timeout wrapped to " + String(timeout))
    assert_equal(timeout, Int32.MAX)


def test_epoll_wait_timeout_without_deadline() raises:
    """No timer armed: 0 when not waiting, -1 (block) when waiting."""
    assert_equal(
        _epoll_wait_timeout_ms(wait=False, has_deadline=False, remaining_ns=0),
        Int32(0),
    )
    assert_equal(
        _epoll_wait_timeout_ms(wait=True, has_deadline=False, remaining_ns=0),
        Int32(-1),
    )


def test_epoll_wait_timeout_with_deadline_but_no_wait_is_zero() raises:
    """A timer armed far ahead must not make a non-waiting tick block."""
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=False, has_deadline=True, remaining_ns=5_000_000_000
        ),
        Int32(0),
    )


def test_epoll_wait_timeout_rounds_partial_millisecond_up() raises:
    """Remaining time is ceiled to whole ms; at or past due gives 0."""
    assert_equal(
        _epoll_wait_timeout_ms(wait=True, has_deadline=True, remaining_ns=1),
        Int32(1),
        "sub-millisecond remainder must round up to 1",
    )
    assert_equal(
        _epoll_wait_timeout_ms(
            wait=True, has_deadline=True, remaining_ns=1_500_000
        ),
        Int32(2),
        "1.5ms must round up to 2 so epoll never wakes before the deadline",
    )
    assert_equal(
        _epoll_wait_timeout_ms(wait=True, has_deadline=True, remaining_ns=0),
        Int32(0),
    )
    assert_equal(
        _epoll_wait_timeout_ms(wait=True, has_deadline=True, remaining_ns=-7),
        Int32(0),
    )


# ── Main ─────────────────────────────────────────────────────────────────────


def _selected(name: String) -> Bool:
    """Return True if `name` should run given the optional argv filter."""
    var args = argv()
    if len(args) < 2:
        return True
    return String(args[1]) == name


def main() raises:
    if _selected("test_nop_submitted_from_callback_fires_on_next_tick"):
        test_nop_submitted_from_callback_fires_on_next_tick()
    if _selected(
        "test_callback_cancelling_its_own_completion_does_not_double_free"
    ):
        test_callback_cancelling_its_own_completion_does_not_double_free()
    if _selected(
        "test_op_cancelled_by_earlier_callback_in_same_batch_fires_once"
    ):
        test_op_cancelled_by_earlier_callback_in_same_batch_fires_once()
    if _selected("test_second_accept_on_same_listener_stays_pending_on_eagain"):
        test_second_accept_on_same_listener_stays_pending_on_eagain()
    if _selected("test_failed_epoll_registration_releases_pool_slot"):
        test_failed_epoll_registration_releases_pool_slot()
    if _selected("test_connect_on_blocking_socket_does_not_block_submit"):
        test_connect_on_blocking_socket_does_not_block_submit()
    if _selected("test_cancel_of_unknown_target_reports_enoent"):
        test_cancel_of_unknown_target_reports_enoent()
    if _selected("test_more_in_flight_ops_than_max_events_all_complete"):
        test_more_in_flight_ops_than_max_events_all_complete()
    if _selected("test_far_future_timer_does_not_block_forever"):
        test_far_future_timer_does_not_block_forever()
    if _selected("test_epoll_wait_timeout_without_deadline"):
        test_epoll_wait_timeout_without_deadline()
    if _selected("test_epoll_wait_timeout_with_deadline_but_no_wait_is_zero"):
        test_epoll_wait_timeout_with_deadline_but_no_wait_is_zero()
    if _selected("test_epoll_wait_timeout_rounds_partial_millisecond_up"):
        test_epoll_wait_timeout_rounds_partial_millisecond_up()
    print("PASS: test_epoll_completion_fixes.mojo")
