"""`BufferPool`: a loop-owned set of fixed-size buffers with lease handles.

`count` rounds up to a power of two; a size outside 64..2^24 or a count
outside 1..32768 is EINVAL, and 32768 (the largest ring the kernel
accepts) works on both backends; dropping the handle releases the slot
at the next sweep once no lease is out and recycles the group id; a
lease returns itself on drop; handles are inert once the loop is gone.
"""

from std.testing import assert_equal, assert_false, assert_true

from boucle.drivers.backend import Backend
from boucle.error import IOError
from boucle.watch import WatchLoop
from boucle.watch.pool import BufferPool, LeasedBuffer


def _run(backend: Backend) raises:
    """Exercise rounding, EINVAL, lease round trip, release and inertness."""
    var loop = WatchLoop(capacity=4, backend=backend)

    var pool = loop.buffer_pool(5, 256)
    assert_equal(pool.capacity(), 8, "count rounds up to a power of two")
    assert_equal(pool.available(), 8)
    assert_equal(pool.buffer_size(), 256)
    assert_equal(loop.in_flight_count(), 1, "a pool occupies one slot")

    var raised = False
    try:
        _ = loop.buffer_pool(4, 63)
    except e:
        raised = "EINVAL" in String(e)
    assert_true(raised, "size below 64 must raise EINVAL")

    raised = False
    try:
        _ = loop.buffer_pool(0, 64)
    except e:
        raised = "EINVAL" in String(e)
    assert_true(raised, "count below 1 must raise EINVAL")

    raised = False
    try:
        _ = loop.buffer_pool(32769, 64)
    except e:
        raised = "EINVAL" in String(e)
    assert_true(raised, "count above 32768 must raise EINVAL")

    raised = False
    try:
        _ = loop.buffer_pool(1, (1 << 24) + 1)
    except e:
        raised = "EINVAL" in String(e)
    assert_true(raised, "size above 2^24 must raise EINVAL")
    assert_equal(
        loop.in_flight_count(), 1, "a rejected pool leaves no slot behind"
    )

    # The largest ring the kernel accepts registers on both backends.
    var largest = loop.buffer_pool(32768, 64)
    assert_equal(largest.capacity(), 32768)
    assert_equal(largest.available(), 32768)
    _ = largest^
    _ = loop.step(0)
    assert_equal(loop.in_flight_count(), 1)

    # A lease taken by hand (what a delivery does) comes back on drop and
    # its bytes view the whole buffer, header included.
    pool._state[].lease_taken()
    var lease = LeasedBuffer(pool._state, UInt16(3))
    assert_equal(pool.available(), 7)
    assert_equal(Int(lease.id()), 3)
    var bytes = lease.bytes()
    assert_equal(len(bytes), 256)
    assert_equal(Int(bytes[0]), 0, "pool memory starts zeroed")
    bytes[0] = UInt8(0xAB)
    assert_equal(Int(pool._state[].buffer_ptr(UInt16(3))[]), 0xAB)
    _ = lease^
    assert_equal(pool.available(), 8)

    # Drop the handle: released at the next sweep.
    _ = pool^
    _ = loop.step(0)
    assert_equal(loop._pools.active(), 0, "pool slot released after drop")
    assert_equal(loop.in_flight_count(), 0)

    # A lease outstanding at drop time keeps the slot until it returns.
    var pool2 = loop.buffer_pool(2, 64)
    pool2._state[].lease_taken()
    var lease2 = LeasedBuffer(pool2._state, UInt16(0))
    _ = pool2^
    _ = loop.step(0)
    assert_equal(loop._pools.active(), 1, "slot held while a lease is out")
    _ = lease2^
    _ = loop.step(0)
    assert_equal(loop._pools.active(), 0)

    # A released pool's group id is handed to the next pool.
    var first = -1
    for _ in range(3):
        var again = loop.buffer_pool(2, 64)
        var gid = Int(again._state[].group_id)
        if first < 0:
            first = gid
        assert_equal(gid, first, "a released group id is reused")
        _ = again^
        _ = loop.step(0)
        assert_equal(loop._pools.active(), 0)


def test_handles_are_inert_after_loop_destruction() raises:
    """A pool and a lease outliving the loop read their state but touch nothing."""
    var loop = WatchLoop(capacity=4, backend=Backend.EPOLL)
    var pool = loop.buffer_pool(2, 64)
    pool._state[].lease_taken()
    var lease = LeasedBuffer(pool._state, UInt16(1))
    _ = loop^
    # The pool slab is leaked for the surviving handles, so the shared box
    # they point at is still readable: the driver was flagged dead before
    # it was torn down.
    assert_false(
        pool._state[]._shared[].driver_alive,
        "driver_alive is cleared before the driver is destroyed",
    )
    assert_true(pool._state[].loop_gone())
    assert_true(
        Int(pool._state[].memory) != 0,
        "with leases only and no stream the memory is kept",
    )
    assert_equal(pool.capacity(), 2)
    assert_equal(pool.available(), 1)
    _ = lease^
    assert_equal(pool.available(), 1, "return is a no-op once the loop is gone")
    _ = pool^


def main() raises:
    _run(Backend.AUTO)
    print("ok: AUTO")
    _run(Backend.EPOLL)
    print("ok: EPOLL")
    test_handles_are_inert_after_loop_destruction()
    print("ok: inert after loop destruction")
    print("PASS: test_buffer_pool.mojo")
