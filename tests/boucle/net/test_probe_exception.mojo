"""Test ProbeBatch exception paths: partial submit and FD leak safety.

Exercises the error-recovery logic that drains only submitted probes
when submit() raises mid-batch (SQ exhaustion), and verifies no FDs
leak on failure paths.
"""

from std.ffi import external_call
from std.testing import assert_true, assert_equal

from boucle.net.probe import ProbeBatch, PortStatus
from boucle.net.addr import SocketAddrV4
from boucle.completion import CompletionLoop


def count_open_fds() -> Int:
    """Count open file descriptors via fcntl F_GETFD."""
    var count = 0
    for fd_num in range(1024):
        var rc = external_call["fcntl", Int32](Int32(fd_num), Int32(1))
        if rc >= 0:
            count += 1
    return count


def test_partial_submit_no_hang() raises:
    """SQ exhaustion mid-batch raises without infinite hang.

    Uses sq_entries=4 with concurrency=5. Each probe needs 2 SQ slots,
    so the 3rd probe's submit() fails. The fix ensures only the 2
    successfully-submitted probes are drained (not all 5).
    """
    var loop = CompletionLoop(sq_entries=4)

    var ports = List[Int]()
    ports.append(1)
    ports.append(2)
    ports.append(3)
    ports.append(4)
    ports.append(5)

    var fds_before = count_open_fds()

    var batch = ProbeBatch(
        target=SocketAddrV4(127, 0, 0, 1, port=0),
        ports=ports^,
        timeout_ms=2000,
        concurrency=5,
    )

    var raised = False
    try:
        batch.run_cooperative(loop)
    except:
        raised = True

    assert_true(raised)

    # No FD leak despite the exception.
    var fds_after = count_open_fds()
    assert_true(fds_after <= fds_before + 1)


def test_partial_submit_small_sq() raises:
    """With sq_entries=4 and concurrency=3, first batch (3 probes) fails on probe 2.

    Verifies the batch terminates (no hang) and cleans up FDs.
    """
    var loop = CompletionLoop(sq_entries=4)

    var ports = List[Int]()
    ports.append(1)
    ports.append(2)
    ports.append(3)

    var fds_before = count_open_fds()

    var batch = ProbeBatch(
        target=SocketAddrV4(127, 0, 0, 1, port=0),
        ports=ports^,
        timeout_ms=2000,
        concurrency=3,
    )

    var raised = False
    try:
        batch.run_cooperative(loop)
    except:
        raised = True

    assert_true(raised)
    var fds_after = count_open_fds()
    assert_true(fds_after <= fds_before + 1)


def test_successful_batch_after_small_concurrency() raises:
    """With sq_entries=4 and concurrency=1, batches of 1 succeed sequentially.

    Each probe only needs 2 slots, and the SQ drains between batches.
    """
    var loop = CompletionLoop(sq_entries=4)

    var ports = List[Int]()
    ports.append(1)
    ports.append(2)
    ports.append(3)

    var batch = ProbeBatch(
        target=SocketAddrV4(127, 0, 0, 1, port=0),
        ports=ports^,
        timeout_ms=2000,
        concurrency=1,
    )
    batch.run_cooperative(loop)
    assert_equal(len(batch.results()), 3)
    for i in range(len(batch.results())):
        assert_true(batch.results()[i].status == PortStatus.CLOSED)


def main() raises:
    test_partial_submit_no_hang()
    test_partial_submit_small_sq()
    test_successful_batch_after_small_concurrency()
    print("PASS: test_probe_exception")
