"""Property test: random port counts x concurrency -> postconditions hold."""

from std.testing import assert_equal, assert_true

from boucle.net.probe import ProbeBatch, PortStatus
from boucle.net.addr import SocketAddrV4
from boucle.proactor.loop import EventLoop
from boucle.drivers.io_uring import IoUringDriver


def test_property(port_count: Int, concurrency: Int) raises:
    """For any (port_count, concurrency), postconditions hold.

    Verifies:
    1. Complete coverage: len(results) == port_count
    2. Valid results: every status is OPEN, CLOSED, or FILTERED
    3. Sorted output: results are in ascending port order

    Args:
        port_count: Number of ports to probe (1..port_count).
        concurrency: Maximum concurrent probes.
    """
    var driver = IoUringDriver(sq_entries=4096)
    var loop = EventLoop[IoUringDriver](driver^)

    var ports = List[Int]()
    for i in range(port_count):
        ports.append(i + 1)  # ports 1..port_count (all refused on loopback)

    var batch = ProbeBatch(
        target=SocketAddrV4(127, 0, 0, 1, port=0),
        ports=ports^,
        timeout_ms=2000,
        concurrency=concurrency,
    )
    batch.run_cooperative(loop)

    # Postcondition: complete coverage
    assert_equal(len(batch.results()), port_count)

    # Postcondition: valid results
    for i in range(len(batch.results())):
        var s = batch.results()[i].status
        assert_true(
            s == PortStatus.OPEN
            or s == PortStatus.CLOSED
            or s == PortStatus.FILTERED
        )

    # Postcondition: sorted by port ascending
    for i in range(1, len(batch.results())):
        assert_true(batch.results()[i].port > batch.results()[i - 1].port)


def main() raises:
    test_property(port_count=0, concurrency=1)
    test_property(port_count=1, concurrency=1)
    test_property(port_count=5, concurrency=1)
    test_property(port_count=5, concurrency=3)
    test_property(port_count=5, concurrency=5)
    test_property(port_count=5, concurrency=100)
    test_property(port_count=10, concurrency=2)
    test_property(port_count=20, concurrency=7)
    print("PASS: test_probe_property")
