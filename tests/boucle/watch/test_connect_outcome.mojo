"""Verify ConnectOutcome decodes CQE results correctly."""

from std.testing import assert_true, assert_false, assert_equal
from boucle.watch.outcome import ConnectOutcome


def test_connect_outcome() raises:
    # 1. Success -> CONNECTED
    var ok = ConnectOutcome.from_cqe_result(0)
    assert_true(ok.is_connected(), "0 should be CONNECTED")
    assert_false(ok.is_refused(), "0 should not be REFUSED")

    # 2. ECONNREFUSED (-111) -> REFUSED
    var refused = ConnectOutcome.from_cqe_result(-111)
    assert_true(refused.is_refused(), "-111 should be REFUSED")

    # 3. ETIMEDOUT (-110) -> TIMEOUT
    var timeout = ConnectOutcome.from_cqe_result(-110)
    assert_true(timeout.is_timeout(), "-110 should be TIMEOUT")

    # 4. ENETUNREACH (-101) -> NETWORK_UNREACHABLE
    var net_unreach = ConnectOutcome.from_cqe_result(-101)
    assert_true(
        net_unreach.is_network_unreachable(),
        "-101 should be NETWORK_UNREACHABLE",
    )

    # 5. EHOSTUNREACH (-113) -> NETWORK_UNREACHABLE
    var host_unreach = ConnectOutcome.from_cqe_result(-113)
    assert_true(
        host_unreach.is_network_unreachable(),
        "-113 should be NETWORK_UNREACHABLE",
    )

    # 6. Unknown error -> ERROR
    var err = ConnectOutcome.from_cqe_result(-99)
    assert_true(err.is_error(), "-99 should be ERROR")
    assert_equal(err.raw_result(), -99)

    # 7. Writable output (smoke test)
    print(ok)
    print(refused)
    print(timeout)
    print(net_unreach)
    print(err)



def main() raises:
    test_connect_outcome()
    print("PASS: test_connect_outcome.mojo")
