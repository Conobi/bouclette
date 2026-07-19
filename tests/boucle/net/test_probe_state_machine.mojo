"""Unit tests for ConnectProbe state machine — no io_uring required.

Directly fires completion callbacks to verify state transitions and
invariants hold for all legal transition sequences.
"""

from std.testing import assert_equal, assert_true
from boucle.net.connect_probe import ConnectProbe
from boucle.net.probe import PortStatus


def test_connect_success_sets_open() raises:
    """Connect fires with result=0 -> result is OPEN, _cancel_submitted=True."""
    var probe = ConnectProbe.for_test()
    probe.wire_context()

    # Simulate connect CQE with success (result=0).
    probe._connect_cmp.fire(result=Int32(0), flags=UInt32(0))

    assert_true(probe.result_is_set())
    assert_true(probe.result_status() == PortStatus.OPEN)
    assert_true(probe._cancel_submitted)
    assert_equal(probe._total_cqes, 1)


def test_timeout_fires_sets_filtered() raises:
    """Timeout fires non-ECANCELED -> result is FILTERED, _cancel_submitted=True."""
    var probe = ConnectProbe.for_test()
    probe.wire_context()

    # Simulate timeout CQE firing (result=-ETIME = -62 typically, use 0 for "expired").
    probe._timeout_cmp.fire(result=Int32(-62), flags=UInt32(0))

    assert_true(probe.result_is_set())
    assert_true(probe.result_status() == PortStatus.FILTERED)
    assert_true(probe._cancel_submitted)
    assert_equal(probe._total_cqes, 1)


def test_ecanceled_does_not_set_result() raises:
    """ECANCELED (-125) does NOT set result, just increments CQE count."""
    var probe = ConnectProbe.for_test()
    probe.wire_context()

    # Simulate connect CQE with ECANCELED.
    probe._connect_cmp.fire(result=Int32(-125), flags=UInt32(0))

    assert_true(not probe.result_is_set())
    assert_equal(probe._total_cqes, 1)
    assert_true(not probe._cancel_submitted)


def test_no_double_set() raises:
    """Second non-ECANCELED callback doesn't set result again (dual-fire guard)."""
    var probe = ConnectProbe.for_test()
    probe.wire_context()

    # First: connect succeeds -> sets OPEN.
    probe._connect_cmp.fire(result=Int32(0), flags=UInt32(0))
    assert_true(probe.result_status() == PortStatus.OPEN)

    # Second: timeout fires (non-ECANCELED) -> should NOT override.
    probe._timeout_cmp.fire(result=Int32(-62), flags=UInt32(0))
    assert_true(probe.result_status() == PortStatus.OPEN)
    assert_equal(probe._total_cqes, 2)


def test_probe_done_at_three_cqes() raises:
    """Probe is_done when _total_cqes reaches 3."""
    var probe = ConnectProbe.for_test()
    probe.wire_context()

    # Sequence: connect success, timeout ECANCELED, cancel CQE.
    probe._connect_cmp.fire(result=Int32(0), flags=UInt32(0))
    assert_true(not probe.is_done())

    probe._timeout_cmp.fire(result=Int32(-125), flags=UInt32(0))
    assert_true(not probe.is_done())

    probe._cancel_cmp.fire(result=Int32(0), flags=UInt32(0))
    assert_true(probe.is_done())
    assert_equal(probe._total_cqes, 3)


def test_cancel_cqe_enoent_increments_count() raises:
    """Cancel CQE with -ENOENT (-2) still increments count normally."""
    var probe = ConnectProbe.for_test()
    probe.wire_context()

    # Sequence: timeout fires, connect ECANCELED, cancel ENOENT.
    probe._timeout_cmp.fire(result=Int32(-62), flags=UInt32(0))
    probe._connect_cmp.fire(result=Int32(-125), flags=UInt32(0))
    probe._cancel_cmp.fire(result=Int32(-2), flags=UInt32(0))

    assert_true(probe.is_done())
    assert_equal(probe._total_cqes, 3)
    assert_true(probe.result_status() == PortStatus.FILTERED)


def test_connect_refused_sets_closed() raises:
    """Connect with -ECONNREFUSED (-111) -> result is CLOSED."""
    var probe = ConnectProbe.for_test()
    probe.wire_context()

    probe._connect_cmp.fire(result=Int32(-111), flags=UInt32(0))

    assert_true(probe.result_is_set())
    assert_true(probe.result_status() == PortStatus.CLOSED)
    assert_true(probe._cancel_submitted)


def main() raises:
    test_connect_success_sets_open()
    test_timeout_fires_sets_filtered()
    test_ecanceled_does_not_set_result()
    test_no_double_set()
    test_probe_done_at_three_cqes()
    test_cancel_cqe_enoent_increments_count()
    test_connect_refused_sets_closed()
    print("PASS: test_probe_state_machine")
