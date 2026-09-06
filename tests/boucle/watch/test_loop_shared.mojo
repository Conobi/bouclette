"""The loop's shared box points at the live driver and follows the loop across
a move. That it is flagged dead before the driver is destroyed is witnessed
by the buffer-pool test, whose leaked pool state keeps the box readable.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.socle.platform import ENOBUFS
from boucle.watch import WatchLoop
from boucle.watch._shared import _LoopShared


def test_shared_points_at_driver_and_follows_a_move() raises:
    """`driver` pointer == address of _driver, before and after moving the loop."""
    var loop = WatchLoop(capacity=4)
    assert_true(loop._shared[].driver_alive, "driver is alive after init")
    assert_equal(
        Int(loop._shared[].driver),
        Int(Pointer(to=loop._driver)),
        "shared.driver names the loop's driver",
    )
    assert_equal(
        Int(loop._shared[].deferred),
        Int(loop._deferred),
        "shared.deferred names the loop's deferred queue",
    )
    assert_equal(loop._shared[].stream_completions, 0)
    assert_equal(loop._shared[].internal_completions, 0)

    var moved = loop^
    assert_equal(
        Int(moved._shared[].driver),
        Int(Pointer(to=moved._driver)),
        "the move constructor re-points shared.driver",
    )
    # A timer still runs on the moved loop, so the pointer is usable.
    var t = moved.timeout(1)
    moved.run()
    assert_true(t.result(), "timer fired on the moved loop")
    _ = moved^


def test_tally_is_reset_per_tick() raises:
    """`reset_tally` zeroes both counters."""
    var deferred = List[Int]()
    var shared = _LoopShared(
        Pointer[List[Int], MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=deferred))
        )
    )
    shared.stream_completions = 3
    shared.internal_completions = 2
    shared.reset_tally()
    assert_equal(shared.stream_completions, 0)
    assert_equal(shared.internal_completions, 0)
    assert_equal(ENOBUFS, 105)
    assert_equal(len(deferred), 0)


def main() raises:
    test_shared_points_at_driver_and_follows_a_move()
    test_tally_is_reset_per_tick()
    print("PASS: test_loop_shared.mojo")
