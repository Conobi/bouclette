"""The deferred flush never dereferences a key whose slot is no longer active.

A composite's key sits on the deferred list until its three completions
have arrived; once the slot is settled the key must be inert even if a
stale copy of it is still queued. The test settles a composite, writes
a poisoned "cancel wanted, not done" state into the freed slot, pushes
the old key back on the deferred list by hand, and steps: nothing is
submitted, nothing is re-queued and the slot stays free. Runs on both
backends.
"""

from std.testing import assert_equal, assert_true

from boucle.drivers.backend import Backend
from boucle.net.addr import SocketAddrV4
from boucle.net.socket import Socket
from boucle.watch import WatchLoop
from boucle.watch._callback import _KIND_BITS


def _settle_one_composite(mut loop: WatchLoop) raises -> Int:
    """Run a connect_with_timeout to a closed port to completion and drop it.

    Args:
        loop: The loop to submit on.

    Returns:
        The slot key the composite occupied.
    """
    var client = Socket.tcp_v4()
    var target = SocketAddrV4(127, 0, 0, 1, port=UInt16(1))
    var future = loop.connect_with_timeout(client, target, 1000)
    var key = future._state[]._link.key
    loop.run()
    assert_true(future.done(), "composite must be done after run()")
    _ = future^
    _ = loop.step(0)  # the sweep releases the orphaned slot
    assert_equal(loop._connects_with_timeout.active(), 0)
    assert_equal(loop.pending_composites(), 0)
    client.close()
    return key


def _run(backend: Backend) raises:
    """A stale composite key on the deferred list is skipped, not flushed."""
    var loop = WatchLoop(capacity=4, backend=backend)
    var key = _settle_one_composite(loop)
    var index = key >> _KIND_BITS

    # Poison the freed slot so that a flush that did dereference it
    # would submit a cancel and re-queue the key.
    var slot = loop._connects_with_timeout._slot(index)
    slot[]._cancel_target = UInt8(1)
    slot[].done = False
    loop._deferred[].append(key)
    assert_equal(loop.pending_composites(), 1)

    assert_equal(loop.step(0), 0, "nothing observable happens")
    assert_equal(loop.pending_composites(), 0, "the stale key is dropped")
    assert_equal(loop._pending, 0, "no cancel was submitted")
    assert_equal(loop._connects_with_timeout.active(), 0, "slot untouched")
    assert_equal(loop.in_flight_count(), 0)
    _ = loop^


def main() raises:
    _run(Backend.AUTO)
    print("ok: AUTO")
    _run(Backend.EPOLL)
    print("ok: EPOLL")
    print("PASS: test_flush_deferred_safety.mojo")
