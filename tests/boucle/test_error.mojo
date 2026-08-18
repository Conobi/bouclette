from boucle.error import IOError
from boucle._sys.linux.errno import Errno
from std.testing import assert_true, assert_false


def test_error() raises:
    var would_block = IOError(Errno.EAGAIN)
    assert_true(would_block.is_would_block())
    assert_false(would_block.is_connection_reset())
    assert_false(would_block.is_timed_out())

    # EWOULDBLOCK == EAGAIN on Linux x86_64
    var would_block2 = IOError(Errno.EWOULDBLOCK)
    assert_true(would_block2.is_would_block())

    var conn_reset = IOError(Errno.ECONNRESET)
    assert_true(conn_reset.is_connection_reset())
    assert_false(conn_reset.is_would_block())

    var conn_refused = IOError(Errno.ECONNREFUSED)
    assert_true(conn_refused.is_connection_refused())

    var broken_pipe = IOError(Errno.EPIPE)
    assert_true(broken_pipe.is_broken_pipe())

    var timed_out = IOError(Errno.ETIMEDOUT)
    assert_true(timed_out.is_timed_out())

    var interrupted = IOError(Errno.EINTR)
    assert_true(interrupted.is_interrupted())


def main() raises:
    test_error()
    print("PASS: test_error.mojo")
