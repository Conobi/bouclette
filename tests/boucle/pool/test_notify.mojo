"""Test eventfd notify and drain."""

from std.ffi import external_call
from std.testing import assert_true
from boucle.pool._notify import create_eventfd, _notify_raw, drain_eventfd


def main() raises:
    var fd = create_eventfd()
    assert_true(fd >= 0, "eventfd creation failed")

    # Notify twice, drain once (eventfd sums).
    _notify_raw(fd)
    _notify_raw(fd)
    drain_eventfd(fd)

    # Second drain should not block (EFD_NONBLOCK).
    drain_eventfd(fd)

    # Close.
    _ = external_call["close", Int32](fd)

    print("PASS: eventfd notify and drain")
