"""The io_uring driver keeps every registered buffer ring in a table keyed
by group id, so return_buffer can find the ring a completion's buffer id
belongs to and unregister_buffer_group can tear the right ring down.

Also exercises the trait-shaped multishot_recvmsg overload that takes an
opaque msghdr pointer. Skips when io_uring is unavailable.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true

from boucle.drivers.io_uring import IoUringDriver
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.proactor.completion import Completion
from boucle.socle.linux.raw import (
    msghdr,
    IORING_CQE_F_BUFFER,
    IORING_CQE_BUFFER_SHIFT,
)


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var d = IoUringDriver(capacity=4)
        _ = d^
        return True
    except:
        return False


struct Tracker:
    """Records every completion fired on one Completion."""

    var count: Int
    var results: Array[Int, 8]
    var flags: Array[UInt32, 8]

    def __init__(out self):
        """Construct an empty tracker."""
        self.count = 0
        self.results = Array[Int, 8](fill=0)
        self.flags = Array[UInt32, 8](fill=UInt32(0))

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """Store result and flags at the next index."""
        var self_ptr = Pointer[Tracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        var i = self_ptr[].count
        if i < 8:
            self_ptr[].results[i] = result
            self_ptr[].flags[i] = flags
        self_ptr[].count += 1


def _ptr[T: AnyType](ref value: T) -> Pointer[T, MutUntrackedOrigin]:
    """Untracked pointer to a caller-owned value."""
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=value))
    )


def test_group_table() raises:
    """`register`/`return`/`unregister` keep the table in step with the kernel."""
    var driver = IoUringDriver(capacity=16)
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](4 * 256))
    )
    driver.register_buffer_group(mem, UInt32(256), 4, UInt16(3))
    assert_equal(len(driver._groups[]), 1)
    assert_equal(Int(driver._groups[][0].bgid), 3)
    assert_equal(Int(driver._groups[][0].buf_count), 4)

    var dup_raised = False
    try:
        driver.register_buffer_group(mem, UInt32(256), 4, UInt16(3))
    except e:
        dup_raised = "EEXIST" in String(e)
    assert_true(dup_raised, "duplicate group id must raise EEXIST")
    assert_equal(len(driver._groups[]), 1)

    driver.return_buffer(UInt16(3), UInt16(0))
    driver.return_buffer(UInt16(9), UInt16(0))  # unknown group: no-op

    var unknown_raised = False
    try:
        driver.unregister_buffer_group(UInt16(9))
    except e:
        unknown_raised = "ENOENT" in String(e)
    assert_true(unknown_raised, "unknown group id must raise ENOENT")

    driver.unregister_buffer_group(UInt16(3))
    assert_equal(len(driver._groups[]), 0)
    mem.unsafe_free()


def test_invalid_arguments_raise_before_touching_the_ring() raises:
    """A zero size, a zero count or a count past the 16-bit id space raise EINVAL."""
    var driver = IoUringDriver(capacity=16)
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](1))
    )

    var too_many = False
    try:
        driver.register_buffer_group(mem, UInt32(64), 65537, UInt16(5))
    except e:
        too_many = "EINVAL" in String(e)
    assert_true(too_many, "count above 65536 must raise EINVAL")

    var zero_count = False
    try:
        driver.register_buffer_group(mem, UInt32(64), 0, UInt16(6))
    except e:
        zero_count = "EINVAL" in String(e)
    assert_true(zero_count, "count == 0 must raise EINVAL")

    var zero_size = False
    try:
        driver.register_buffer_group(mem, UInt32(0), 4, UInt16(7))
    except e:
        zero_size = "EINVAL" in String(e)
    assert_true(zero_size, "size == 0 must raise EINVAL")

    # Nothing was recorded, so every id is still free to register.
    assert_equal(len(driver._groups[]), 0)
    mem.unsafe_free()


def test_multishot_via_opaque_pointer() raises:
    """The trait-shaped overload delivers into a registered group."""
    var driver = IoUringDriver(capacity=16)
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var to = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](4 * 256))
    )
    driver.register_buffer_group(mem, UInt32(256), 4, UInt16(2))
    var tmpl = msghdr()
    tmpl.msg_namelen = UInt32(28)
    var tracker = Tracker()
    var cmp = Completion(
        invoke=Tracker.on_complete,
        context=_ptr(tracker).unsafe_bitcast[NoneType](),
    )
    driver.multishot_recvmsg(
        receiver.raw(),
        _ptr(tmpl).unsafe_bitcast[NoneType](),
        UInt16(2),
        _ptr(cmp),
    )
    _ = driver.tick(wait=False)
    var payload = List[UInt8](length=3, fill=UInt8(ord("x")))
    assert_equal(sender.send_to(Span(payload), to), 3)
    var ticks = 0
    while tracker.count < 1:
        _ = driver.tick(wait=True, timeout_ms=1000)
        ticks += 1
        assert_true(ticks < 50, "no delivery")
    assert_true((tracker.flags[0] & UInt32(IORING_CQE_F_BUFFER)) != 0)
    # io_uring_recvmsg_out header (16) + msg_namelen (28) + payload (3).
    assert_equal(tracker.results[0], 16 + 28 + 3)
    var bid = UInt16(tracker.flags[0] >> UInt32(IORING_CQE_BUFFER_SHIFT))
    driver.return_buffer(UInt16(2), bid)
    driver.unregister_buffer_group(UInt16(2))
    mem.unsafe_free()
    receiver.close()
    sender.close()
    _ = tmpl
    _ = tracker
    _ = cmp


def main() raises:
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_group_table()
    test_invalid_arguments_raise_before_touching_the_ring()
    test_multishot_via_opaque_pointer()
    print("PASS: test_driver_buffer_group.mojo")
