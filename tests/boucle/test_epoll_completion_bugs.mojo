"""Tests targeting known bugs in the epoll completion backend.

Each test either reproduces a bug (red until fixed) or guards against
a regression in a fragile invariant.

All tests force Backend.EPOLL to exercise the epoll-specific code paths.
"""

from boucle.completion import CompletionLoop
from boucle.proactor.completion import Completion
from boucle.drivers.backend import Backend
from boucle.handle import RawHandle
from boucle.socle.linux.raw import ECANCELED, syscall, __NR_write
from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true


# ── Shared callback struct ───────────────────────────────────────────────


struct IOSlot:
    """Records one completion with result AND flags."""

    var result: Int
    var flags: UInt32
    var fired: Bool

    def __init__(out self):
        """Construct an unfired slot."""
        self.result = 0
        self.flags = UInt32(0)
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records result and flags."""
        var self_ptr = Pointer[IOSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].flags = flags
        self_ptr[].fired = True


def _make_socketpair() raises -> Array[Int32, 2]:
    """Create an AF_UNIX SOCK_STREAM socketpair."""
    var sv = Array[Int32, 2](fill=0)
    var res = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1),  # SOCK_STREAM
        0,
        Pointer(to=sv).unsafe_bitcast[Int32](),
    )
    assert_equal(Int(res), 0, "socketpair failed")
    return sv^


def _make_completion(
    slot: Pointer[IOSlot, MutUntrackedOrigin],
) -> Completion:
    """Create a Completion wired to an IOSlot."""
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(slot)
    )
    return Completion(invoke=IOSlot.on_complete, context=ctx)


# ── Test 1: Stale fd fires spurious completion ───────────────────────────


def test_stale_fd_spurious_dispatch() raises:
    """Issue 1: After recv completes, _dispatch_op frees the pool slot but
    does NOT call EPOLL_CTL_DEL. The fd stays in epoll with a stale
    _EpollOp pointer as data. If new data arrives on the fd, epoll_wait
    returns the stale pointer and _dispatch_op dereferences it.

    This test sends more data after completion and ticks again. Correct
    behavior: no pending op, dispatch nothing. Bug: spurious completion
    from the stale pointer.
    """
    var sv = _make_socketpair()
    var fd_a: RawHandle = sv[0]
    var fd_b: RawHandle = sv[1]
    var loop = CompletionLoop(sq_entries=8, backend=Backend.EPOLL)

    # Submit and complete a recv.
    var slot = IOSlot()
    var cmp = _make_completion(
        Pointer[IOSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=slot))
        )
    )
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )
    var buf = List[UInt8](length=16, fill=0)
    var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )

    loop.recv(fd_a, buf_ptr, UInt32(16), cmp_ptr)
    var msg = UInt8(0xCC)
    _ = syscall[__NR_write, Scalar[DType.int64]](
        fd_b, Pointer(to=msg), UInt64(1)
    )
    _ = loop.tick(wait=True)
    assert_true(slot.fired, "recv did not complete")

    # Reset the slot to detect spurious fires.
    slot.fired = False
    slot.result = 0

    # Send MORE data — fd is still in epoll with stale pointer.
    var msg2 = UInt8(0xDD)
    _ = syscall[__NR_write, Scalar[DType.int64]](
        fd_b, Pointer(to=msg2), UInt64(1)
    )

    # Correct behavior: no pending recv, so tick should dispatch nothing.
    var dispatched = loop.tick(wait=False)

    assert_equal(dispatched, 0, "no pending op — should dispatch nothing")
    assert_true(not slot.fired, "no pending op — callback should not fire")

    _ = external_call["close", Int32](fd_a)
    _ = external_call["close", Int32](fd_b)
    _ = cmp


# ── Test 2: ECANCELED constant consistency ───────────────────────────────


def test_ecanceled_constant() raises:
    """Issue 6: connect_timeout.mojo checks `result == -125` as a
    magic number instead of using the named ECANCELED constant.

    Regression guard: verifies the magic number matches the constant so
    a platform divergence is caught immediately. Also tests the cancel
    path end-to-end on epoll.
    """
    # Part 1: Constant consistency.
    assert_equal(
        -125,
        -Int(ECANCELED),
        "magic -125 must equal -ECANCELED",
    )

    # Part 2: Cancel a pending recv on epoll backend.
    var sv = _make_socketpair()
    var fd_a: RawHandle = sv[0]
    var fd_b: RawHandle = sv[1]
    var loop = CompletionLoop(sq_entries=8, backend=Backend.EPOLL)

    # Submit recv (will block — no data sent).
    var recv_slot = IOSlot()
    var recv_cmp = _make_completion(
        Pointer[IOSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=recv_slot))
        )
    )
    var recv_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=recv_cmp))
    )
    var buf = List[UInt8](length=16, fill=0)
    var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    loop.recv(fd_a, buf_ptr, UInt32(16), recv_cmp_ptr)

    # Submit cancel targeting the recv.
    var cancel_slot = IOSlot()
    var cancel_cmp = _make_completion(
        Pointer[IOSlot, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=cancel_slot))
        )
    )
    var cancel_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cancel_cmp))
    )
    loop.cancel(recv_cmp_ptr, cancel_cmp_ptr)

    _ = loop.tick(wait=False)

    assert_true(recv_slot.fired, "cancelled recv did not fire")
    assert_equal(
        recv_slot.result,
        -Int(ECANCELED),
        "cancelled recv should get -ECANCELED",
    )
    assert_true(cancel_slot.fired, "cancel op did not fire")
    assert_equal(
        cancel_slot.result,
        0,
        "cancel op itself should succeed with 0",
    )

    _ = external_call["close", Int32](fd_a)
    _ = external_call["close", Int32](fd_b)
    _ = recv_cmp
    _ = cancel_cmp


# ── Main ─────────────────────────────────────────────────────────────────


def main() raises:
    test_stale_fd_spurious_dispatch()
    test_ecanceled_constant()
    print("PASS: test_epoll_completion_bugs.mojo")
