"""`TimeoutUpdate` writes the SQE liburing's `io_uring_prep_timeout_update` writes, and re-arms a live timer.

The layout check reads the fields back from the SQE the builder filled
(no submission). The round trip arms a 5 s TIMEOUT and shortens it to
10 ms in the same submit: the update reports 0 and the timer reports
-ETIME well under 500 ms.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from boucle.socle.linux.io_uring import IoUring
from boucle.socle.linux.io_uring.op import Timeout, TimeoutUpdate
from boucle.socle.linux.io_uring.types import IoUringOp, IoUringTimeoutFlags
from boucle.socle.linux.raw import (
    __kernel_timespec,
    ETIME,
    IORING_TIMEOUT_ABS,
    IORING_TIMEOUT_UPDATE,
)
from boucle.socle.linux.raw.ctypes import c_void


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var ring = IoUring[](sq_entries=4)
        ring^.__deinit__()
        return True
    except:
        return False


def _ts_ptr(ref ts: __kernel_timespec) -> Pointer[c_void, MutUntrackedOrigin]:
    """Opaque pointer to a timespec the caller keeps alive."""
    return Pointer[c_void, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=ts))
    )


def test_flag_values() raises:
    """The two raw constants match the uapi and the struct composes them."""
    assert_equal(IORING_TIMEOUT_ABS, 1)
    assert_equal(IORING_TIMEOUT_UPDATE, 2)
    assert_equal(Int(IoUringTimeoutFlags().value), 0)
    assert_equal(Int(IoUringTimeoutFlags.ABS.value), 1)
    assert_equal(Int(IoUringTimeoutFlags.UPDATE.value), 2)
    assert_equal(
        Int((IoUringTimeoutFlags.ABS | IoUringTimeoutFlags.UPDATE).value), 3
    )


def test_sqe_layout() raises:
    """Opcode TIMEOUT_REMOVE, fd -1, addr = target, off = timespec, len 0, op_flags = UPDATE."""
    var ring = IoUring[](sq_entries=4)
    var ts = __kernel_timespec(1, 0)
    var sq = ring.sq()
    var op = TimeoutUpdate(sq.__next__(), UInt64(42), _ts_ptr(ts)).user_data(
        UInt64(7)
    )
    assert_equal(op.sqe[].opcode.id, IoUringOp.TIMEOUT_REMOVE.id)
    assert_equal(Int(op.sqe[].fd), -1)
    assert_equal(op.sqe[].addr_or_splice_off_in_or_msgring_cmd, UInt64(42))
    assert_equal(op.sqe[].off_or_addr2_or_cmd_op, UInt64(Int(Pointer(to=ts))))
    assert_equal(op.sqe[].len_or_poll_flags, UInt32(0))
    assert_equal(op.sqe[].op_flags, UInt32(IORING_TIMEOUT_UPDATE))
    assert_equal(op.sqe[].user_data, UInt64(7))

    # Extra flags keep the UPDATE bit.
    var abs_op = op^.timeout_flags(IoUringTimeoutFlags.ABS)
    assert_equal(
        abs_op.sqe[].op_flags,
        UInt32(IORING_TIMEOUT_ABS | IORING_TIMEOUT_UPDATE),
    )
    _ = abs_op^
    _ = ts


def test_update_rearms_a_live_timer() raises:
    """A 5 s timer updated to 10 ms in the same submit fires -ETIME; the update reports 0."""
    var ring = IoUring[](sq_entries=4)
    var long_ts = __kernel_timespec(5, 0)
    var short_ts = __kernel_timespec(0, 10_000_000)
    var sq = ring.sq()
    _ = Timeout(sq.__next__(), _ts_ptr(long_ts)).user_data(UInt64(1))
    _ = TimeoutUpdate(sq.__next__(), UInt64(1), _ts_ptr(short_ts)).user_data(
        UInt64(2)
    )
    var start = perf_counter_ns()
    _ = ring.submit_and_wait(wait_nr=2)
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    assert_true(
        elapsed_ms < 500, "the update did not shorten the timer: " + String(elapsed_ms)
    )

    var seen = 0
    var update_res = Int32(1)
    var timer_res = Int32(1)
    var cq = ring.cq(wait_nr=0)
    while cq:
        var cqe = cq.__next__()
        if cqe.user_data == UInt64(2):
            update_res = cqe.res
        elif cqe.user_data == UInt64(1):
            timer_res = cqe.res
        seen += 1
    cq^.__deinit__()
    assert_equal(seen, 2)
    assert_equal(Int(update_res), 0)
    assert_equal(Int(timer_res), -Int(ETIME))
    _ = long_ts
    _ = short_ts


def main() raises:
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_flag_values()
    print("ok: flag values")
    test_sqe_layout()
    print("ok: SQE layout")
    test_update_rearms_a_live_timer()
    print("ok: update re-arms a live timer")
    print("PASS: test_timeout_update.mojo")
