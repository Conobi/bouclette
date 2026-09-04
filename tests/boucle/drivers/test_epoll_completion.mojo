"""Tests for EpollCompletionDriver.

Verifies the epoll-based completion emulation: nop (deferred-ready
queue) and timeout (userspace timer heap with -ETIME result).
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.proactor.completion import Completion
from boucle.drivers.epoll_completion import EpollCompletionDriver
from boucle.socle.linux.raw import __kernel_timespec, ETIME


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


def main() raises:
    test_nop_fires_with_zero()
    test_timeout_fires_with_etime()
    print("All epoll completion driver tests passed.")
