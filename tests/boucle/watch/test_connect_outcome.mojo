"""Verify ConnectOutcome decodes results correctly.

Both drivers deliver connect results as *negated* errnos: io_uring forwards
`cqe.res` verbatim and epoll_completion negates `SO_ERROR`. The positive form
is accepted too so callers never have to think about the sign.
"""

from std.testing import assert_true, assert_false, assert_equal
from boucle.error import IOError
from boucle.watch.outcome import ConnectOutcome


def test_connect_outcome() raises:
    # 1. Success -> CONNECTED
    var ok = ConnectOutcome.from_result(0)
    assert_true(ok.is_connected(), "0 should be CONNECTED")
    assert_false(ok.is_refused(), "0 should not be REFUSED")

    # 2. ECONNREFUSED (-111) -> REFUSED
    var refused = ConnectOutcome.from_result(-111)
    assert_true(refused.is_refused(), "-111 should be REFUSED")

    # 3. ETIMEDOUT (-110) -> TIMEOUT
    var timeout = ConnectOutcome.from_result(-110)
    assert_true(timeout.is_timeout(), "-110 should be TIMEOUT")

    # 4. ENETUNREACH (-101) -> NETWORK_UNREACHABLE
    var net_unreach = ConnectOutcome.from_result(-101)
    assert_true(
        net_unreach.is_network_unreachable(),
        "-101 should be NETWORK_UNREACHABLE",
    )

    # 5. EHOSTUNREACH (-113) -> NETWORK_UNREACHABLE
    var host_unreach = ConnectOutcome.from_result(-113)
    assert_true(
        host_unreach.is_network_unreachable(),
        "-113 should be NETWORK_UNREACHABLE",
    )

    # 6. Unknown error -> ERROR, errno kept as a positive number
    var err = ConnectOutcome.from_result(-99)
    assert_true(err.is_error(), "-99 should be ERROR")
    assert_equal(err.raw_result(), 99)

    # 7. Writable output (smoke test)
    print(ok)
    print(refused)
    print(timeout)
    print(net_unreach)
    print(err)


def test_driver_value_matches_constant() raises:
    """The value the drivers actually deliver must classify as REFUSED."""
    assert_equal(ConnectOutcome.from_result(-111), ConnectOutcome.REFUSED)
    assert_equal(ConnectOutcome.from_result(-110), ConnectOutcome.TIMEOUT)
    assert_equal(ConnectOutcome.from_result(0), ConnectOutcome.CONNECTED)


def test_both_signs_normalise() raises:
    """A positive errno decodes exactly like its negated form."""
    assert_equal(ConnectOutcome.from_result(111), ConnectOutcome.REFUSED)
    assert_equal(
        ConnectOutcome.from_result(111).raw_result(),
        ConnectOutcome.from_result(-111).raw_result(),
    )
    assert_equal(ConnectOutcome.REFUSED.raw_result(), 111)
    assert_equal(ConnectOutcome.TIMEOUT.raw_result(), 110)
    assert_equal(ConnectOutcome.NETWORK_UNREACHABLE.raw_result(), 101)


def test_equality_is_on_tag_only() raises:
    """EHOSTUNREACH and ENETUNREACH are the same outcome, not the same errno."""
    var host = ConnectOutcome.from_result(-113)
    assert_equal(host, ConnectOutcome.NETWORK_UNREACHABLE)
    assert_equal(host.raw_result(), 113)
    assert_true(ConnectOutcome.from_result(-99) == ConnectOutcome.ERROR)
    assert_true(ConnectOutcome.REFUSED != ConnectOutcome.TIMEOUT)


def test_error_bridges_to_ioerror() raises:
    """A failed outcome hands back the same errno as IOError."""
    assert_equal(
        ConnectOutcome.from_result(-111).error(),
        IOError.from_errno(111),
    )
    assert_equal(
        ConnectOutcome.from_result(0).error(),
        IOError.from_errno(0),
    )


def test_writable_names_the_errno() raises:
    assert_equal(
        String(ConnectOutcome.from_result(-111)),
        "ConnectOutcome.REFUSED(ECONNREFUSED (111))",
    )
    assert_equal(String(ConnectOutcome.CONNECTED), "ConnectOutcome.CONNECTED")


def main() raises:
    test_connect_outcome()
    test_driver_value_matches_constant()
    test_both_signs_normalise()
    test_equality_is_on_tag_only()
    test_error_bridges_to_ioerror()
    test_writable_names_the_errno()
    print("PASS: test_connect_outcome.mojo")
