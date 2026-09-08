from boucle.socle.linux.io_uring import (
    IoUring,
    io_uring_setup,
    io_uring_enter,
    IoUringParams,
    IoUringEnterFlags,
    IoUringSetupFlags,
    OwnedFd,
    NO_ENTER_ARG,
)
from std.testing import assert_true, assert_equal


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var ring = IoUring[](sq_entries=4)
        ring^.__deinit__()
        return True
    except:
        return False


def test_setup() raises:
    # --- Test 1: io_uring_setup with 16 entries returns a valid fd ---
    var params = IoUringParams()
    params.flags |= IoUringSetupFlags.NO_SQARRAY
    var fd = io_uring_setup[False](UInt32(16), params)
    assert_true(fd.unsafe_fd() > -1, "io_uring_setup should return a valid fd")

    # --- Test 2: Kernel fills IoUringParams correctly ---
    assert_equal(Int(params.sq_entries), 16, "sq_entries should be 16")
    assert_equal(Int(params.cq_entries), 32, "cq_entries should be 2x sq_entries")

    # --- Test 3: Ring offsets are sane ---
    assert_equal(Int(params.sq_off.head), 0, "sq_off.head should be 0")
    assert_equal(Int(params.sq_off.tail), 4, "sq_off.tail should be 4")
    assert_equal(Int(params.cq_off.cqes), 64, "cq_off.cqes should be 64")

    # --- Test 4: io_uring_enter with GETEVENTS works (returns 0 for no-op) ---
    var result = io_uring_enter(
        fd,
        to_submit=UInt32(0),
        min_complete=UInt32(0),
        flags=IoUringEnterFlags.GETEVENTS,
        arg=NO_ENTER_ARG,
    )
    assert_equal(Int(result), 0, "io_uring_enter with no work should return 0")

    # --- Test 5: io_uring_enter EINTR-retry wrapper passes through cleanly ---
    # Regression test for the EINTR-retry loop. We can't easily inject a real
    # EINTR (would need fork + signal), but exercise the wrapper repeatedly
    # on an idle ring to confirm the loop terminates with a clean zero result
    # in the common no-signal case.
    for _ in range(4):
        var idle = io_uring_enter(
            fd,
            to_submit=UInt32(0),
            min_complete=UInt32(0),
            flags=IoUringEnterFlags.GETEVENTS,
            arg=NO_ENTER_ARG,
        )
        assert_equal(
            Int(idle), 0, "idle io_uring_enter must not raise or spin"
        )


def test_setup_with_taskrun_flags() raises:
    """A ring set up with the deferred task-work flags answers an idle GETEVENTS enter with 0.

    `DEFER_TASKRUN` requires `SINGLE_ISSUER` (EINVAL otherwise) and makes
    an enter from any thread but the creator fail with EEXIST. This is
    the creating thread, so the enter must succeed with no completions.
    Kernel 6.1 or later; the ring already needs 6.6 for `NO_SQARRAY`.
    """
    var params = IoUringParams()
    params.flags |= (
        IoUringSetupFlags.NO_SQARRAY
        | IoUringSetupFlags.SINGLE_ISSUER
        | IoUringSetupFlags.DEFER_TASKRUN
        | IoUringSetupFlags.COOP_TASKRUN
        | IoUringSetupFlags.TASKRUN_FLAG
    )
    var fd = io_uring_setup[False](UInt32(16), params)
    assert_true(
        fd.unsafe_fd() > -1,
        "io_uring_setup with the task-work flags should return a valid fd",
    )
    assert_true(
        Bool(params.flags & IoUringSetupFlags.DEFER_TASKRUN),
        "the kernel must hand the requested flags back unchanged",
    )
    var result = io_uring_enter(
        fd,
        to_submit=UInt32(0),
        min_complete=UInt32(0),
        flags=IoUringEnterFlags.GETEVENTS,
        arg=NO_ENTER_ARG,
    )
    assert_equal(
        Int(result), 0,
        "idle GETEVENTS enter on a DEFER_TASKRUN ring should return 0",
    )


def main() raises:
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_setup()
    test_setup_with_taskrun_flags()
    print("PASS: test_setup.mojo")
