"""Test 10: supports(MULTISHOT_RECVMSG) predicts a live multishot recvmsg.

True: a multishot recvmsg over a provided-buffer ring on a loopback UDP
socket delivers a datagram with a buffer id and the MORE flag. False:
the driver refuses the submission with EOPNOTSUPP before the kernel
would answer -EINVAL in the CQE. AutoDriver's choice follows the rule.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc as _heap_alloc
from std.testing import assert_equal, assert_true

from boucle.drivers import DriverFeature
from boucle.drivers.auto import AutoDriver
from boucle.drivers.backend import Backend
from boucle.drivers.io_uring import IoUringDriver
from boucle.error import IOError
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.proactor import Completion, buffer_id, has_more
from boucle.socle.linux.raw import EOPNOTSUPP, iovec, msghdr

comptime NUM_BUFS = 4
comptime BUF_SIZE = 512
comptime GROUP_ID = UInt16(3)


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var d = IoUringDriver(capacity=4)
        _ = d^
        return True
    except:
        return False


struct Delivery:
    """Records the first multishot completion."""

    var count: Int
    var result: Int
    var flags: UInt32

    def __init__(out self):
        """Construct an empty record."""
        self.count = 0
        self.result = 0
        self.flags = UInt32(0)

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Keep the first completion; count the rest."""
        var self_ptr = Pointer[Delivery, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        if self_ptr[].count == 0:
            self_ptr[].result = result
            self_ptr[].flags = flags
        self_ptr[].count += 1


def _run_multishot(mut driver: IoUringDriver) raises:
    """Submit a multishot recvmsg, send one datagram, check the delivery."""
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var port = receiver.local_addr_v4().port
    var sender = Socket.udp_v4()

    var buf_base = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(_heap_alloc[UInt8](NUM_BUFS * BUF_SIZE))
    )
    for i in range(NUM_BUFS * BUF_SIZE):
        buf_base[unsafe_offset=i] = UInt8(0)
    var ring = driver.register_buf_ring(
        buf_base, UInt32(BUF_SIZE), NUM_BUFS, group_id=GROUP_ID
    )

    var iov = iovec()
    var hdr = msghdr()
    hdr.msg_iov = UInt64(Int(Pointer(to=iov)))
    hdr.msg_iovlen = 1
    var hdr_ptr = Pointer[msghdr, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=hdr))
    )

    var delivery = Delivery()
    var cmp = Completion(
        invoke=Delivery.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=delivery))
        ),
    )
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )
    driver.multishot_recvmsg(receiver.raw(), hdr_ptr, GROUP_ID, cmp_ptr)
    _ = driver.tick(False)

    var payload = String("ping")
    _ = sender.send_to(payload.as_bytes(), SocketAddrV4(127, 0, 0, 1, port=port))

    var ticks = 0
    while delivery.count == 0:
        _ = driver.tick(True, 1000)
        ticks += 1
        if ticks > 5:
            raise "no multishot delivery within 5 s"

    assert_true(delivery.result > 0, "delivery must carry bytes")
    var id = buffer_id(delivery.flags)
    assert_true(Bool(id), "delivery must name a provided buffer")
    assert_true(Int(id.value()) < NUM_BUFS, "buffer id out of range")
    assert_true(has_more(delivery.flags), "first delivery keeps the op armed")

    ring.add_buffer(id.value())
    driver.unregister_buf_ring(group_id=GROUP_ID)
    buf_base.unsafe_free()
    _ = cmp
    _ = hdr
    _ = iov
    _ = ring^
    receiver.close()
    sender.close()


def _expect_eopnotsupp(mut driver: IoUringDriver) raises:
    """An unsupported multishot recvmsg is refused at submission."""
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var iov = iovec()
    var hdr = msghdr()
    hdr.msg_iov = UInt64(Int(Pointer(to=iov)))
    hdr.msg_iovlen = 1
    var hdr_ptr = Pointer[msghdr, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=hdr))
    )
    var delivery = Delivery()
    var cmp = Completion(
        invoke=Delivery.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=delivery))
        ),
    )
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )
    var fd = receiver.raw()
    var raised = False
    try:
        driver.multishot_recvmsg(fd, hdr_ptr, GROUP_ID, cmp_ptr)
    except e:
        raised = True
        assert_equal(IOError.from_error(e).errno_value(), EOPNOTSUPP)
    assert_true(raised, "unsupported multishot recvmsg must raise")
    _ = cmp
    _ = hdr
    _ = iov
    receiver.close()


def test_supports_predicts_multishot() raises:
    """`supports(MULTISHOT_RECVMSG)` decides which branch the kernel takes."""
    var driver = IoUringDriver(capacity=16)
    if driver.supports(DriverFeature.MULTISHOT_RECVMSG):
        print("  multishot recvmsg supported: running a live delivery")
        _run_multishot(driver)
    else:
        print("  multishot recvmsg unsupported: expecting EOPNOTSUPP")
        _expect_eopnotsupp(driver)


def test_auto_follows_the_rule() raises:
    """AutoDriver picks io_uring iff both datagram features are native."""
    var probe = IoUringDriver(capacity=4)
    var native = probe.supports(DriverFeature.MULTISHOT_RECVMSG) and probe.supports(
        DriverFeature.BUFFER_RING
    )
    _ = probe^
    var auto = AutoDriver(capacity=4)
    if native:
        assert_true(auto.backend() is Backend.IO_URING)
    else:
        assert_true(auto.backend() is Backend.EPOLL)


def main() raises:
    if not _has_io_uring():
        var auto = AutoDriver(capacity=4)
        assert_true(auto.backend() is Backend.EPOLL)
        print("SKIP: io_uring not available; AUTO fell back to epoll")
        return
    test_supports_predicts_multishot()
    test_auto_follows_the_rule()
    print("PASS: test_probe_multishot.mojo")
