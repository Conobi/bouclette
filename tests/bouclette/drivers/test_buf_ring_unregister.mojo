"""Register and unregister argument structs must reach the kernel fully written.

A reserved field left holding stack garbage makes the kernel reject the call
with EINVAL, so a group that is unregistered must be registrable again.
Run with `-O1` or `-O3` as well as the default.
"""

from bouclette.drivers.io_uring import IoUringDriver
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc as _heap_alloc
from std.testing import assert_equal


def _has_buf_ring() -> Bool:
    try:
        var d = IoUringDriver(capacity=4)
        var probe = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(_heap_alloc[UInt8](4 * 64))
        )
        var ok = True
        try:
            _ = d.register_buf_ring(probe, 64, 4, 1)
            d.unregister_buf_ring(1)
        except:
            ok = False
        probe.unsafe_free()
        return ok
    except:
        return False


def test_buf_ring_unregister_then_reregister() raises:
    if not _has_buf_ring():
        return  # kernel without provided-buffer rings
    comptime BUF_SIZE = 64
    comptime BUF_COUNT = 4
    var driver = IoUringDriver(capacity=4)
    var pool = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(_heap_alloc[UInt8](BUF_SIZE * BUF_COUNT))
    )
    for _ in range(8):
        var bring = driver.register_buf_ring(
            pool, UInt32(BUF_SIZE), BUF_COUNT, UInt16(7)
        )
        assert_equal(Int(bring.bgid), 7)
        # Raises EINVAL if the unregister argument carried garbage.
        driver.unregister_buf_ring(UInt16(7))
    pool.unsafe_free()


def main() raises:
    test_buf_ring_unregister_then_reregister()
