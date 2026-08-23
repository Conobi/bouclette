from boucle.socle.linux.io_uring import IoUring
from boucle.socle.linux.io_uring.op import Nop
from std.testing import assert_equal


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var ring = IoUring[](sq_entries=4)
        ring^.__deinit__()
        return True
    except:
        return False


def test_nop() raises:
    var ring = IoUring[](sq_entries=16)

    # Submit 16 NOPs
    var to_submit = 0
    var sq = ring.sq()
    while sq:
        _ = Nop(sq.__next__()).user_data(1)
        to_submit += 1
    assert_equal(to_submit, 16)

    # Submit and wait
    _ = ring.submit_and_wait(wait_nr=UInt32(to_submit))

    # Drain completions
    var completed = 0
    var cq = ring.cq(wait_nr=0)
    while cq:
        var cqe = cq.__next__()
        assert_equal(cqe.user_data, UInt64(1))
        completed += 1
    cq^.__deinit__()
    assert_equal(completed, to_submit)


def main() raises:
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_nop()
    print("PASS: test_nop.mojo")
