from boucle.watch import WatchLoop
from std.testing import assert_equal


def test_create() raises:
    """WatchLoop can be created."""
    var loop = WatchLoop(capacity=8)
    assert_equal(loop._pending, 0)


def test_run_empty() raises:
    """Run on an empty loop returns immediately."""
    var loop = WatchLoop(capacity=8)
    loop.run()


def main() raises:
    test_create()
    test_run_empty()
    print("WatchLoop basic tests passed.")
