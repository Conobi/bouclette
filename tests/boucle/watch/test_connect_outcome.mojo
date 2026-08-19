"""Verify ConnectOutcome decodes CQE results correctly."""

from std.testing import assert_true, assert_false, assert_equal
from boucle.watch.outcome import ConnectOutcome
from boucle.net.probe import PortStatus


def main() raises:
    # 1. Success -> CONNECTED
    var ok = ConnectOutcome.from_cqe_result(Int32(0))
    assert_true(ok.is_connected(), "0 should be CONNECTED")
    assert_false(ok.is_refused(), "0 should not be REFUSED")
    assert_true(
        ok.port_status() == PortStatus.OPEN, "CONNECTED -> OPEN"
    )

    # 2. ECONNREFUSED (-111) -> REFUSED
    var refused = ConnectOutcome.from_cqe_result(Int32(-111))
    assert_true(refused.is_refused(), "-111 should be REFUSED")
    assert_true(
        refused.port_status() == PortStatus.CLOSED, "REFUSED -> CLOSED"
    )

    # 3. ETIMEDOUT (-110) -> TIMEOUT
    var timeout = ConnectOutcome.from_cqe_result(Int32(-110))
    assert_true(timeout.is_timeout(), "-110 should be TIMEOUT")
    assert_true(
        timeout.port_status() == PortStatus.FILTERED, "TIMEOUT -> FILTERED"
    )

    # 4. ENETUNREACH (-101) -> NETWORK_UNREACHABLE
    var net_unreach = ConnectOutcome.from_cqe_result(Int32(-101))
    assert_true(
        net_unreach.is_network_unreachable(),
        "-101 should be NETWORK_UNREACHABLE",
    )
    assert_true(
        net_unreach.port_status() == PortStatus.FILTERED,
        "NETWORK_UNREACHABLE -> FILTERED",
    )

    # 5. EHOSTUNREACH (-113) -> NETWORK_UNREACHABLE
    var host_unreach = ConnectOutcome.from_cqe_result(Int32(-113))
    assert_true(
        host_unreach.is_network_unreachable(),
        "-113 should be NETWORK_UNREACHABLE",
    )

    # 6. Unknown error -> ERROR
    var err = ConnectOutcome.from_cqe_result(Int32(-99))
    assert_true(err.is_error(), "-99 should be ERROR")
    assert_equal(err.raw_result(), Int32(-99))
    assert_true(
        err.port_status() == PortStatus.FILTERED, "ERROR -> FILTERED"
    )

    # 7. Writable output (smoke test)
    print(ok)
    print(refused)
    print(timeout)
    print(net_unreach)
    print(err)

    print("PASS: ConnectOutcome decodes all CQE result codes correctly")
