"""Verify actual I/O operations work under the epoll backend.

Forces Backend.EPOLL and exercises nop and timeout to confirm
the completion-over-epoll path is functional.
"""

from boucle.proactor.completion_loop import CompletionLoop
from boucle.drivers.backend import Backend
from boucle.proactor.completion import Completion
from boucle.socle.linux.raw import __kernel_timespec, ETIME
from std.testing import assert_equal, assert_true
from std.memory import Pointer


struct _NopSlot:
    """Records a nop completion result."""

    var result: Int
    var fired: Bool

    def __init__(out self):
        """Construct an unfired slot."""
        self.result = -999
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the result."""
        var self_ptr = Pointer[_NopSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


struct _TimeoutSlot:
    """Records a timeout completion result."""

    var result: Int
    var fired: Bool

    def __init__(out self):
        """Construct an unfired slot."""
        self.result = -999
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the result."""
        var self_ptr = Pointer[_TimeoutSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


def test_epoll_nop() raises:
    """Nop fires on the next tick with result=0."""
    var slot = _NopSlot()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var cmp = Completion(invoke=_NopSlot.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    var loop = CompletionLoop(capacity=4, backend=Backend.EPOLL)
    assert_true(loop.backend() is Backend.EPOLL)

    loop.nop(cmp_ptr)
    var dispatched = loop.tick(wait=False)
    assert_equal(dispatched, 1, "nop should dispatch on tick")
    assert_true(slot.fired, "nop callback should have fired")
    assert_equal(Int(slot.result), 0, "nop result should be 0")

    _ = cmp


def test_epoll_timeout() raises:
    """Timeout fires after the deadline with result=-ETIME."""
    var slot = _TimeoutSlot()
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=slot))
    )
    var cmp = Completion(invoke=_TimeoutSlot.on_complete, context=ctx)
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )

    var loop = CompletionLoop(capacity=4, backend=Backend.EPOLL)

    # 50ms timeout via __kernel_timespec (layout matches Timeout).
    var ts = __kernel_timespec(0, 50_000_000)
    var ts_ptr = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=ts))
    )
    loop.timeout(ts_ptr, cmp_ptr)

    # Tick with wait=True should block until the timer fires.
    var ticks = 0
    while not slot.fired:
        _ = loop.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for timeout completion"

    assert_true(slot.fired, "timeout callback should have fired")
    # ETIME is errno 62 on Linux, so result should be -62.
    assert_equal(Int(slot.result), -Int(ETIME), "timeout result should be -ETIME (-62)")

    _ = cmp
    _ = ts


def main() raises:
    test_epoll_nop()
    test_epoll_timeout()
    print("PASS: test_epoll_backend.mojo")
