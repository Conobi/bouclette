from boucle._sys.linux.fd import close, dup, UnsafeFd, NoFd, unsafe_fd_as_arg
from std.testing import assert_true


def test_fd() raises:
    # NoFd sentinel is -1
    assert_true(NoFd == -1)

    # Dup stdin (fd 0) to get a valid fd
    var fd: UnsafeFd = dup(unsafe_fd=0)
    assert_true(fd > -1)

    # unsafe_fd_as_arg validates and returns the fd
    var validated = unsafe_fd_as_arg(fd)
    assert_true(validated == fd)

    # unsafe_fd_as_arg raises on negative fd
    var caught_neg = False
    try:
        _ = unsafe_fd_as_arg(Int32(-1))
    except:
        caught_neg = True
    assert_true(caught_neg)

    # Close the duped fd (checked version)
    close(unsafe_fd=fd)

    # close raises on invalid (negative) fd
    var caught_close = False
    try:
        close(unsafe_fd=Int32(-1))
    except:
        caught_close = True
    assert_true(caught_close)


def main() raises:
    test_fd()
    print("PASS: test_fd.mojo")
