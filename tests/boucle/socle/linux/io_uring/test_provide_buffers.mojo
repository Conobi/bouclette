"""Test provide_buffers via IoUringDriver.

Verifies that the SQE-based buffer provisioning completes
successfully (result >= 0).
"""

from boucle.drivers.io_uring import IoUringDriver
from boucle.proactor.completion import Completion
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc as _heap_alloc
from std.testing import assert_equal, assert_true


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var d = IoUringDriver(capacity=4)
        _ = d^
        return True
    except:
        return False


struct Tracker:
    """Records a single provide_buffers completion."""

    var called: Bool
    var result: Int

    def __init__(out self):
        """Construct an unfired tracker."""
        self.called = False
        self.result = 0

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the completion result."""
        var self_ptr = Pointer[Tracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].called = True
        self_ptr[].result = result
        print(
            "on_complete: result=",
            result,
            " flags=",
            flags,
        )


def test_provide_buffers() raises:
    """Register 4 x 256-byte buffers via IoUringDriver and verify success."""
    # 4 buffers x 256 bytes = 1024 bytes total
    comptime BUF_SIZE = 256
    comptime BUF_COUNT = 4
    var pool = _heap_alloc[UInt8](BUF_SIZE * BUF_COUNT)
    for i in range(BUF_SIZE * BUF_COUNT):
        pool[unsafe_offset=i] = 0

    print("pool address=", Int(pool))

    var driver = IoUringDriver()

    # Wire completion callback.
    var tracker = Tracker()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=tracker))
    )
    var cmp = Completion(invoke=Tracker.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    driver.provide_buffers(
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(pool)),
        buf_size=BUF_SIZE,
        count=BUF_COUNT,
        group_id=UInt16(1),
        base_buf_id=UInt16(0),
        c=cmp_ptr,
    )
    _ = driver.tick(wait=True)

    assert_true(tracker.called, "on_complete was not called")
    assert_true(
        tracker.result >= 0,
        "provide_buffers failed with result=" + String(tracker.result),
    )

    pool.unsafe_free()
    _ = cmp
    print("test_provide_buffers PASSED")


def main() raises:
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_provide_buffers()
