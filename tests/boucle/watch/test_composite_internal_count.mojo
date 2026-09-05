"""The composite state counts cancel completions for the loop to exclude.

step() returns only completions the caller can observe. The cancel a
connect_with_timeout submits for its loser is internal, so its
completion is tallied by the state and taken by the loop after the
tick.
"""

from std.memory import Pointer
from std.testing import assert_equal

from boucle.net.addr import SocketAddrStorAny, SocketAddrV4
from boucle.timeout import Timeout
from boucle.watch.connect_timeout import _ConnectWithTimeoutState


def test_cancel_completion_is_counted_once() raises:
    """Only the cancel callback increments; take() resets."""
    var addr = SocketAddrV4(127, 0, 0, 1, port=UInt16(1))
    var state = _ConnectWithTimeoutState(
        SocketAddrStorAny(addr.addr_stor()), Timeout.from_ms(Int64(10))
    )
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=state))
    )
    assert_equal(state.take_internal_completions(), 0)

    # The connect loses with ECONNREFUSED: observable, not internal.
    _ConnectWithTimeoutState._on_connect_cb(ctx, -111, UInt32(0))
    assert_equal(state.take_internal_completions(), 0)

    # The cancel's own completion: internal.
    _ConnectWithTimeoutState._on_cancel_cb(ctx, 0, UInt32(0))
    assert_equal(state.take_internal_completions(), 1)
    assert_equal(state.take_internal_completions(), 0)

    # The cancelled timeout: observable (it belongs to the handle).
    _ConnectWithTimeoutState._on_timeout_cb(ctx, -125, UInt32(0))
    assert_equal(state.take_internal_completions(), 0)
    assert_equal(state.done, True)


def main() raises:
    test_cancel_completion_is_counted_once()
    print("PASS: test_composite_internal_count.mojo")
