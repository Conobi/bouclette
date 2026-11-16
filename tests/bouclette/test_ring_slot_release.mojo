"""Rings created and dropped in sequence must not exhaust the per-task registered-ring table.

The kernel gives each task 16 registered-ring slots. A ring that fails to
hand its slot back makes setup 17+ fail with EBUSY, and AUTO then silently
falls back to epoll. The leak only showed at -O1 and above, so run this
test with `-O1` or `-O3` as well as the default.
"""

from bouclette.drivers.backend import Backend
from bouclette.watch.loop import WatchLoop
from std.testing import assert_true


def test_sequential_rings_release_their_slots() raises:
    var first = WatchLoop(capacity=64)
    if not (first.backend() is Backend.IO_URING):
        return  # io_uring is not the AUTO backend on this host
    _ = first^
    for _ in range(64):
        var loop = WatchLoop(capacity=64)
        assert_true(
            loop.backend() is Backend.IO_URING,
            "ring fell back to epoll: registered-ring slots leaked",
        )


def main() raises:
    test_sequential_rings_release_their_slots()
