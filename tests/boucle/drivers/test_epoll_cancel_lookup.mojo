"""`EpollCompletionDriver.cancel` finds its target through the completion index, not a scan.

Two cases the index must get right: a completion whose slot was freed
and handed to another op (the free list is LIFO) answers -ENOENT and
leaves the new occupant alone; a target allocated after the pool grew
past its initial 64 slots is still found.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal, assert_true

from boucle.drivers.epoll_completion import EpollCompletionDriver
from boucle.proactor.completion import Completion
from boucle.socle.linux.raw import __kernel_timespec, ECANCELED, ENOENT, ETIME

comptime GROWN = 70


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


def _slot_completion(ref slot: ResultSlot) -> Completion:
    """A Completion that records into `slot`."""
    return Completion(
        invoke=ResultSlot.on_complete,
        context=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=slot))
        ),
    )


def _completion_ptr(ref c: Completion) -> Pointer[Completion, MutUntrackedOrigin]:
    """Untracked pointer to a completion the caller keeps alive."""
    return Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=c))
    )


def _ts_ptr(ref ts: __kernel_timespec) -> Pointer[NoneType, MutUntrackedOrigin]:
    """Opaque pointer to a timespec the caller keeps alive."""
    return Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=ts))
    )


def test_freed_slot_reused_and_stale_target_reports_enoent() raises:
    """A completes and frees its slot, B takes it; cancel(A) is -ENOENT and B survives."""
    var driver = EpollCompletionDriver(capacity=8)
    var a_slot = ResultSlot()
    var a_cmp = _slot_completion(a_slot)
    var b_slot = ResultSlot()
    var b_cmp = _slot_completion(b_slot)
    var short_ts = __kernel_timespec(0, 1_000_000)
    var long_ts = __kernel_timespec(5, 0)

    driver.timeout(_ts_ptr(short_ts), _completion_ptr(a_cmp))
    var a_index = driver._state[].pool.lookup(Int(_completion_ptr(a_cmp)))
    assert_true(a_index, "A is indexed while armed")

    var ticks = 0
    while not a_slot.fired:
        _ = driver.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for A"
    assert_equal(a_slot.result, -Int(ETIME))
    assert_true(
        not driver._state[].pool.lookup(Int(_completion_ptr(a_cmp))),
        "A's key must leave the index when its slot is freed",
    )

    driver.timeout(_ts_ptr(long_ts), _completion_ptr(b_cmp))
    var b_index = driver._state[].pool.lookup(Int(_completion_ptr(b_cmp)))
    assert_true(b_index, "B is indexed")
    assert_equal(b_index.value(), a_index.value(), "LIFO free list hands B A's slot")

    var cancel_a_slot = ResultSlot()
    var cancel_a_cmp = _slot_completion(cancel_a_slot)
    driver.cancel(_completion_ptr(a_cmp), _completion_ptr(cancel_a_cmp))
    assert_equal(driver.tick(wait=False), 1, "only the cancel's own completion")
    assert_equal(cancel_a_slot.result, -Int(ENOENT))
    assert_true(not b_slot.fired, "B must not be hit by a cancel aimed at A")

    var cancel_b_slot = ResultSlot()
    var cancel_b_cmp = _slot_completion(cancel_b_slot)
    driver.cancel(_completion_ptr(b_cmp), _completion_ptr(cancel_b_cmp))
    assert_equal(driver.tick(wait=False), 2, "B's -ECANCELED and the cancel's 0")
    assert_equal(b_slot.result, -Int(ECANCELED))
    assert_equal(cancel_b_slot.result, 0)

    _ = a_cmp
    _ = b_cmp
    _ = cancel_a_cmp
    _ = cancel_b_cmp
    _ = short_ts
    _ = long_ts


def test_cancel_finds_target_after_pool_growth() raises:
    """70 armed timers grow the pool past 64 slots; the first and the last are still found."""
    var driver = EpollCompletionDriver(capacity=8)
    var slots = unsafe_alloc[ResultSlot](GROWN)
    var cmps = unsafe_alloc[Completion](GROWN)
    var ts = __kernel_timespec(5, 0)
    for i in range(GROWN):
        slots.unsafe_offset(i).unsafe_write(ResultSlot())
        cmps.unsafe_offset(i).unsafe_write(
            Completion(
                invoke=ResultSlot.on_complete,
                context=slots.unsafe_offset(i).unsafe_bitcast[NoneType](),
            )
        )
        driver.timeout(_ts_ptr(ts), cmps.unsafe_offset(i))
    assert_true(
        driver._state[].pool.capacity() > 64,
        "the pool must have grown past its initial 64 slots",
    )

    var first_slot = ResultSlot()
    var first_cmp = _slot_completion(first_slot)
    driver.cancel(cmps.unsafe_offset(0), _completion_ptr(first_cmp))
    assert_equal(driver.tick(wait=False), 2)
    assert_equal(first_slot.result, 0, "target allocated before growth is found")
    assert_equal(slots[unsafe_offset=0].result, -Int(ECANCELED))

    var last_slot = ResultSlot()
    var last_cmp = _slot_completion(last_slot)
    driver.cancel(cmps.unsafe_offset(GROWN - 1), _completion_ptr(last_cmp))
    assert_equal(driver.tick(wait=False), 2)
    assert_equal(last_slot.result, 0, "target allocated after growth is found")
    assert_equal(slots[unsafe_offset=GROWN - 1].result, -Int(ECANCELED))

    _ = first_cmp
    _ = last_cmp
    _ = ts
    slots.unsafe_free()
    cmps.unsafe_free()


def main() raises:
    test_freed_slot_reused_and_stale_target_reports_enoent()
    print("ok: freed slot reused, stale target reports -ENOENT")
    test_cancel_finds_target_after_pool_growth()
    print("ok: cancel finds target after pool growth")
    print("PASS: test_epoll_cancel_lookup.mojo")
