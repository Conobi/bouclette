"""Tests for Socket.set_blocking().

Creates a NONBLOCK socket, verifies O_NONBLOCK is set, toggles
blocking mode, and verifies the flag state.
"""

from std.ffi import external_call
from std.testing import assert_true, assert_equal

from boucle.net.socket import Socket
from boucle.socle.linux.raw import O_NONBLOCK, F_GETFL


def _get_flags(fd: Int32) -> Int32:
    """Read fd flags via fcntl(fd, F_GETFL, 0)."""
    return external_call["fcntl", Int32](fd, Int32(F_GETFL), Int32(0))


def main() raises:
    # tcp_v4() creates a NONBLOCK socket
    var s = Socket.tcp_v4()
    var fd = s._handle._raw

    # Verify O_NONBLOCK is set initially
    var flags0 = _get_flags(fd)
    assert_true(
        (Int(flags0) & O_NONBLOCK) != 0,
        "O_NONBLOCK should be set on a NONBLOCK socket",
    )

    # set_blocking(True) → clear O_NONBLOCK
    s.set_blocking(True)
    var flags1 = _get_flags(fd)
    assert_equal(
        Int(flags1) & O_NONBLOCK, 0,
        "O_NONBLOCK should be cleared after set_blocking(True)",
    )

    # set_blocking(False) → set O_NONBLOCK again
    s.set_blocking(False)
    var flags2 = _get_flags(fd)
    assert_true(
        (Int(flags2) & O_NONBLOCK) != 0,
        "O_NONBLOCK should be set after set_blocking(False)",
    )

    s.close()
    print("PASS: Socket.set_blocking()")
