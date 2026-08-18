"""Tests for Socket.take_error().

Verifies that a fresh socket has no pending error.
"""

from std.testing import assert_true

from boucle.net.socket import Socket


def main() raises:
    var s = Socket.tcp_v4()

    var err = s.take_error()
    assert_true(not err, "fresh socket should have no pending error")

    s.close()
    print("PASS: Socket.take_error()")
