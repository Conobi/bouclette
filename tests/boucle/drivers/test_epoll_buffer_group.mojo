"""Buffer groups on the epoll completion driver are userspace free lists.

register_buffer_group records base pointer, size and a free list of every
buffer id; return_buffer pushes an id back; unregister_buffer_group
forgets the group. Duplicate and unknown ids are rejected the way the
kernel rejects them (EEXIST, ENOENT).
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true

from boucle.drivers.epoll_completion import EpollCompletionDriver


def test_register_return_unregister() raises:
    """A group starts with every id free, pop/return keep the count, unregister drops it."""
    var driver = EpollCompletionDriver(capacity=8)
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](4 * 64))
    )
    driver.register_buffer_group(mem, UInt32(64), 4, UInt16(3))
    assert_equal(len(driver._state[].groups), 1)
    assert_equal(Int(driver._state[].groups[0].id), 3)
    assert_equal(Int(driver._state[].groups[0].size), 64)
    assert_equal(Int(driver._state[].groups[0].count), 4)
    assert_equal(len(driver._state[].groups[0].free), 4)
    # Ids are popped lowest first, so the first delivery uses buffer 0.
    var first = driver._state[].groups[0].free.pop()
    assert_equal(Int(first), 0)
    assert_equal(len(driver._state[].groups[0].free), 3)
    driver.return_buffer(UInt16(3), first)
    assert_equal(len(driver._state[].groups[0].free), 4)

    # Unknown group: return_buffer is a silent no-op.
    driver.return_buffer(UInt16(9), UInt16(0))
    assert_equal(len(driver._state[].groups[0].free), 4)

    driver.unregister_buffer_group(UInt16(3))
    assert_equal(len(driver._state[].groups), 0)
    mem.unsafe_free()


def test_duplicate_and_unknown_ids_raise() raises:
    """Registering an id twice raises EEXIST; unregistering an unknown id raises ENOENT."""
    var driver = EpollCompletionDriver(capacity=8)
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](2 * 64))
    )
    driver.register_buffer_group(mem, UInt32(64), 2, UInt16(1))
    var dup_raised = False
    try:
        driver.register_buffer_group(mem, UInt32(64), 2, UInt16(1))
    except e:
        dup_raised = "EEXIST" in String(e)
    assert_true(dup_raised, "second register of the same id must raise EEXIST")

    var unknown_raised = False
    try:
        driver.unregister_buffer_group(UInt16(7))
    except e:
        unknown_raised = "ENOENT" in String(e)
    assert_true(unknown_raised, "unregister of an unknown id must raise ENOENT")

    driver.unregister_buffer_group(UInt16(1))
    mem.unsafe_free()


def test_count_over_16bit_range_raises() raises:
    """65537 buffers would wrap `UInt16(65536)` to 0, duplicating id 0 in the free list."""
    var driver = EpollCompletionDriver(capacity=8)
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](1))
    )
    var raised = False
    try:
        driver.register_buffer_group(mem, UInt32(64), 65537, UInt16(5))
    except e:
        raised = "EINVAL" in String(e)
    assert_true(raised, "count above 65536 must raise EINVAL")
    mem.unsafe_free()


def test_count_zero_raises() raises:
    """An empty buffer group is useless, and `count - 1` underflow paths are a trap."""
    var driver = EpollCompletionDriver(capacity=8)
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](1))
    )
    var raised = False
    try:
        driver.register_buffer_group(mem, UInt32(64), 0, UInt16(6))
    except e:
        raised = "EINVAL" in String(e)
    assert_true(raised, "count == 0 must raise EINVAL")
    mem.unsafe_free()


def test_count_at_boundary_succeeds() raises:
    """65536 is exactly the 16-bit id space: it must succeed with every id distinct."""
    var driver = EpollCompletionDriver(capacity=8)
    var mem = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(unsafe_alloc[UInt8](1))
    )
    driver.register_buffer_group(mem, UInt32(64), 65536, UInt16(7))
    assert_equal(len(driver._state[].groups[0].free), 65536)

    var seen = List[Bool](capacity=65536)
    for _ in range(65536):
        seen.append(False)
    while len(driver._state[].groups[0].free) > 0:
        var buf_id = driver._state[].groups[0].free.pop()
        assert_true(not seen[Int(buf_id)], "duplicate id in free list")
        seen[Int(buf_id)] = True

    driver.unregister_buffer_group(UInt16(7))
    mem.unsafe_free()


def main() raises:
    test_register_return_unregister()
    test_duplicate_and_unknown_ids_raise()
    test_count_over_16bit_range_raises()
    test_count_zero_raises()
    test_count_at_boundary_succeeds()
    print("PASS: test_epoll_buffer_group.mojo")
