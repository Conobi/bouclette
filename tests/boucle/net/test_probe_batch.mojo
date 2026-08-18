"""Test ProbeBatch: concurrency control, FD leak detection, complete coverage."""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from boucle.net.probe import PortStatus, ProbeResult, ProbeBatch
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


def test_batch_all_refused() raises:
    """Batch of 5 ports on 127.0.0.1 with nothing listening -> all CLOSED."""
    var loop = CompletionLoop(sq_entries=256)

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
        concurrency=3,
    )
    batch.run_cooperative(loop)

    assert_equal(len(batch.results()), 5)
    for i in range(len(batch.results())):
        assert_true(batch.results()[i].status == PortStatus.CLOSED)

    # No FD leak
    var fds_after = count_open_fds()
    assert_true(fds_after <= fds_before + 1)  # +1 tolerance for io_uring fd


def test_batch_empty_ports() raises:
    """Empty port list -> immediate return, empty results."""
    var loop = CompletionLoop(sq_entries=64)

    var batch = ProbeBatch(
        target=SocketAddrV4(127, 0, 0, 1, port=0),
        ports=List[Int](),
        timeout_ms=1000,
        concurrency=10,
    )
    batch.run_cooperative(loop)
    assert_equal(len(batch.results()), 0)


def test_batch_concurrency_one() raises:
    """Concurrency=1 -> strictly sequential probing."""
    var loop = CompletionLoop(sq_entries=64)

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


def test_results_sorted() raises:
    """Results are sorted by port number ascending."""
    var loop = CompletionLoop(sq_entries=256)

    var ports = List[Int]()
    ports.append(5)
    ports.append(3)
    ports.append(1)
    ports.append(4)
    ports.append(2)

    var batch = ProbeBatch(
        target=SocketAddrV4(127, 0, 0, 1, port=0),
        ports=ports^,
        timeout_ms=2000,
        concurrency=5,
    )
    batch.run_cooperative(loop)
    assert_equal(len(batch.results()), 5)
    for i in range(1, len(batch.results())):
        assert_true(batch.results()[i].port > batch.results()[i - 1].port)


def main() raises:
    test_batch_empty_ports()
    test_batch_all_refused()
    test_batch_concurrency_one()
    test_results_sorted()
    print("PASS: test_probe_batch")
