"""Tests for Socket.set_recv_timeout() and Socket.set_send_timeout().

Verifies that setting timeouts does not crash and that ms=0 (disable)
also succeeds.
"""

from std.testing import assert_true

from boucle.net.socket import Socket


def main() raises:
    var s = Socket.tcp_v4()

    # Set recv timeout to 500ms — should not raise.
    s.set_recv_timeout(UInt64(500))

    # Set send timeout to 1000ms — should not raise.
    s.set_send_timeout(UInt64(1000))

    # Disable both by setting to 0 — should not raise.
    s.set_recv_timeout(UInt64(0))
    s.set_send_timeout(UInt64(0))

    s.close()
    print("PASS: Socket.set_recv_timeout() and set_send_timeout()")
