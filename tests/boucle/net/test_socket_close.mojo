from boucle.net.socket import Socket
from std.testing import assert_true


def test_explicit_close() raises:
    """Socket.close() closes the fd. Destructor does not double-close."""
    var sock = Socket.tcp_v4()
    var fd = sock.raw()
    assert_true(fd >= 0)
    sock.close()
    # Destructor fires at scope exit — must not crash.


def test_close_idempotent() raises:
    """Calling close() twice does not crash."""
    var sock = Socket.tcp_v4()
    sock.close()
    sock.close()


def main() raises:
    test_explicit_close()
    test_close_idempotent()
    print("All socket close tests passed.")
