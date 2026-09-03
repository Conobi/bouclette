"""Unit tests for pure probe functions — no io_uring required."""

from std.testing import assert_equal, assert_true
from boucle.net.probe import (
    PortStatus,
    ProbeResult,
    result_from_connect_cqe,
    compute_batches,
    BatchSpec,
)


def test_port_status_equality() raises:
    assert_true(PortStatus.OPEN != PortStatus.CLOSED)
    assert_true(PortStatus.OPEN != PortStatus.FILTERED)
    assert_true(PortStatus.CLOSED != PortStatus.FILTERED)
    assert_true(PortStatus.OPEN == PortStatus.OPEN)


def test_result_from_connect_cqe() raises:
    assert_true(result_from_connect_cqe(0) == PortStatus.OPEN)
    assert_true(result_from_connect_cqe(-111) == PortStatus.CLOSED)
    assert_true(result_from_connect_cqe(-113) == PortStatus.FILTERED)
    assert_true(result_from_connect_cqe(-110) == PortStatus.FILTERED)
    assert_true(result_from_connect_cqe(-99) == PortStatus.FILTERED)


def test_compute_batches_empty() raises:
    var batches = compute_batches(total=0, concurrency=10)
    assert_equal(len(batches), 0)


def test_compute_batches_single() raises:
    var batches = compute_batches(total=5, concurrency=10)
    assert_equal(len(batches), 1)
    assert_equal(batches[0].offset, 0)
    assert_equal(batches[0].size, 5)


def test_compute_batches_multiple() raises:
    var batches = compute_batches(total=10, concurrency=3)
    assert_equal(len(batches), 4)
    assert_equal(batches[0].offset, 0)
    assert_equal(batches[0].size, 3)
    assert_equal(batches[3].offset, 9)
    assert_equal(batches[3].size, 1)


def test_compute_batches_exact() raises:
    var batches = compute_batches(total=6, concurrency=3)
    assert_equal(len(batches), 2)
    assert_equal(batches[0].size, 3)
    assert_equal(batches[1].size, 3)


def test_probe_result_fields() raises:
    var r = ProbeResult(port=443, status=PortStatus.OPEN)
    assert_equal(r.port, 443)
    assert_true(r.status == PortStatus.OPEN)


def main() raises:
    test_port_status_equality()
    test_result_from_connect_cqe()
    test_compute_batches_empty()
    test_compute_batches_single()
    test_compute_batches_multiple()
    test_compute_batches_exact()
    test_probe_result_fields()
    print("PASS: test_probe_pure")
