"""Test TimerFuture and WatchLoop.timeout().

Submits a short timeout via WatchLoop and verifies it expires.
"""

from std.testing import assert_true

from boucle.watch import WatchLoop, TimerFuture


def test_timeout_expires() raises:
    """WatchLoop.timeout() expires after the given duration."""
    var loop = WatchLoop(capacity=8)
    var timer_f = loop.timeout(50)  # 50ms
    loop.run()

    assert_true(timer_f.done(), "timer should be done after run()")
    var expired = timer_f.result()
    assert_true(expired, "timer should have expired")


def main() raises:
    test_timeout_expires()
    print("TimerFuture tests passed.")
