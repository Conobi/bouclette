"""`supports()` on the epoll driver, AutoDriver and CompletionLoop.

The epoll completion driver emulates every feature in userspace, so it
answers True to all of them. AutoDriver delegates to whichever backend
it picked. CompletionLoop passes the question through.
"""

from std.testing import assert_equal, assert_true

from boucle.drivers import DriverFeature
from boucle.drivers.auto import AutoDriver
from boucle.drivers.backend import Backend
from boucle.drivers.epoll_completion import EpollCompletionDriver
from boucle.drivers.io_uring import IoUringDriver
from boucle.proactor.completion_loop import CompletionLoop


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var d = IoUringDriver(capacity=4)
        _ = d^
        return True
    except:
        return False


def test_epoll_supports_everything() raises:
    """Emulation makes every feature available on epoll."""
    var d = EpollCompletionDriver(capacity=4)
    assert_true(d.supports(DriverFeature.MULTISHOT_RECVMSG))
    assert_true(d.supports(DriverFeature.BUFFER_RING))
    assert_true(d.supports(DriverFeature.TIMEOUT_ARG))


def test_auto_forced_epoll_supports_everything() raises:
    """AutoDriver on epoll answers as the epoll driver does."""
    var d = AutoDriver(capacity=4, backend=Backend.EPOLL)
    assert_true(d.supports(DriverFeature.MULTISHOT_RECVMSG))
    assert_true(d.supports(DriverFeature.BUFFER_RING))
    assert_true(d.supports(DriverFeature.TIMEOUT_ARG))


def test_auto_forced_io_uring_delegates() raises:
    """AutoDriver on io_uring answers as the io_uring driver does."""
    if not _has_io_uring():
        print("  SKIP: io_uring not available")
        return
    var uring = IoUringDriver(capacity=4)
    var auto = AutoDriver(capacity=4, backend=Backend.IO_URING)
    assert_equal(
        auto.supports(DriverFeature.MULTISHOT_RECVMSG),
        uring.supports(DriverFeature.MULTISHOT_RECVMSG),
    )
    assert_equal(
        auto.supports(DriverFeature.BUFFER_RING),
        uring.supports(DriverFeature.BUFFER_RING),
    )
    assert_equal(
        auto.supports(DriverFeature.TIMEOUT_ARG),
        uring.supports(DriverFeature.TIMEOUT_ARG),
    )


def test_completion_loop_passes_through() raises:
    """CompletionLoop exposes the driver's answers."""
    var cl = CompletionLoop(capacity=4, backend=Backend.EPOLL)
    assert_true(cl.supports(DriverFeature.MULTISHOT_RECVMSG))
    assert_true(cl.supports(DriverFeature.BUFFER_RING))
    assert_true(cl.supports(DriverFeature.TIMEOUT_ARG))


def main() raises:
    test_epoll_supports_everything()
    test_auto_forced_epoll_supports_everything()
    test_auto_forced_io_uring_delegates()
    test_completion_loop_passes_through()
    print("PASS: test_supports.mojo")
