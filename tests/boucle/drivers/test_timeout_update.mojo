"""`AutoDriver.timeout_update` on both backends: shorten a live timer, refuse an unknown target.

A 5 s timeout updated to 10 ms completes -ETIME within 500 ms and the
update reports 0. An update aimed at a completion that was never
submitted reports -ENOENT and nothing else fires.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.drivers.auto import AutoDriver
from boucle.drivers.backend import Backend
from boucle.proactor.completion import Completion
from boucle.socle.linux.raw import __kernel_timespec, ENOENT, ETIME


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


def _check_update_shortens(backend: Backend) raises:
    """5 s timeout updated to 10 ms: update 0, timer -ETIME within 500 ms."""
    var driver = AutoDriver(capacity=16, backend=backend)
    var timer_slot = ResultSlot()
    var timer_cmp = _slot_completion(timer_slot)
    var update_slot = ResultSlot()
    var update_cmp = _slot_completion(update_slot)
    var long_ts = __kernel_timespec(5, 0)
    var short_ts = __kernel_timespec(0, 10_000_000)

    driver.timeout(_ts_ptr(long_ts), _completion_ptr(timer_cmp))
    driver.timeout_update(
        _ts_ptr(short_ts), _completion_ptr(timer_cmp), _completion_ptr(update_cmp)
    )

    var start = perf_counter_ns()
    var ticks = 0
    while not (timer_slot.fired and update_slot.fired):
        _ = driver.tick(wait=True, timeout_ms=500)
        ticks += 1
        if ticks > 20:
            raise "timed out waiting for the timer and the update"
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    assert_true(elapsed_ms < 500, "timer did not move: " + String(elapsed_ms))
    assert_equal(update_slot.result, 0, "update must report success")
    assert_equal(timer_slot.result, -Int(ETIME), "timer must expire at the new deadline")

    _ = timer_cmp
    _ = update_cmp
    _ = long_ts
    _ = short_ts


def _check_update_unknown_target(backend: Backend) raises:
    """An update on a never-submitted completion reports -ENOENT."""
    var driver = AutoDriver(capacity=16, backend=backend)
    var never_submitted = Completion()
    var update_slot = ResultSlot()
    var update_cmp = _slot_completion(update_slot)
    var ts = __kernel_timespec(0, 10_000_000)

    driver.timeout_update(
        _ts_ptr(ts), _completion_ptr(never_submitted), _completion_ptr(update_cmp)
    )
    var ticks = 0
    while not update_slot.fired:
        _ = driver.tick(wait=True, timeout_ms=100)
        ticks += 1
        if ticks > 20:
            raise "timed out waiting for the update completion"
    assert_equal(update_slot.result, -Int(ENOENT))

    _ = never_submitted
    _ = update_cmp
    _ = ts


def _check_all(backend: Backend) raises:
    """Run every check on one backend."""
    _check_update_shortens(backend)
    _check_update_unknown_target(backend)


def main() raises:
    _check_all(Backend.AUTO)
    print("ok: AUTO")
    _check_all(Backend.EPOLL)
    print("ok: EPOLL")
    print("PASS: test_timeout_update.mojo")
