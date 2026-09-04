"""Verify the runtime probe selects the correct backend.

Probes io_uring availability independently, then asserts AUTO
selected the matching backend. Also verifies forced-backend
construction and rejection.
"""

from boucle.proactor.completion_loop import CompletionLoop
from boucle.watch.loop import WatchLoop
from boucle.drivers.backend import Backend
from boucle.drivers.io_uring import IoUringDriver
from std.testing import assert_true


def _has_io_uring() -> Bool:
    """Independently probe whether io_uring is available."""
    try:
        var d = IoUringDriver(capacity=4)
        _ = d^
        return True
    except:
        return False


def test_auto_selects_correct_backend() raises:
    """AUTO must select io_uring when available, epoll otherwise."""
    var uring_available = _has_io_uring()
    var cl = CompletionLoop(capacity=4)

    if uring_available:
        assert_true(
            cl.backend() is Backend.IO_URING,
            "AUTO should select IO_URING when io_uring is available",
        )
    else:
        assert_true(
            cl.backend() is Backend.EPOLL,
            "AUTO should fall back to EPOLL when io_uring is unavailable",
        )


def test_forced_epoll_always_works() raises:
    """EPOLL backend must succeed on any Linux kernel."""
    var cl = CompletionLoop(capacity=4, backend=Backend.EPOLL)
    assert_true(cl.backend() is Backend.EPOLL)

    var wl = WatchLoop(capacity=4, backend=Backend.EPOLL)
    assert_true(wl.backend() is Backend.EPOLL)


def test_forced_io_uring_behavior() raises:
    """IO_URING backend must raise when unavailable, succeed when available."""
    if _has_io_uring():
        var cl = CompletionLoop(capacity=4, backend=Backend.IO_URING)
        assert_true(cl.backend() is Backend.IO_URING)
        print("  (io_uring available — verified forced IO_URING succeeds)")
    else:
        var raised = False
        try:
            var cl = CompletionLoop(capacity=4, backend=Backend.IO_URING)
            _ = cl
        except:
            raised = True
        assert_true(raised, "forced IO_URING should raise when unavailable")
        print("  (io_uring unavailable — verified forced IO_URING raises)")


def test_watchloop_auto_matches_completion() raises:
    """WatchLoop and CompletionLoop should select the same backend under AUTO."""
    var cl = CompletionLoop(capacity=4)
    var wl = WatchLoop(capacity=4)
    assert_true(
        cl.backend() is wl.backend(),
        "AUTO should select the same backend for both loops",
    )


def main() raises:
    test_auto_selects_correct_backend()
    test_forced_epoll_always_works()
    test_forced_io_uring_behavior()
    test_watchloop_auto_matches_completion()
    print("PASS: test_backend_probe.mojo")
