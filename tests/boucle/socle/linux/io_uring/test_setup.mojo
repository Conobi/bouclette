from boucle.socle.linux.io_uring import (
    io_uring_setup,
    io_uring_enter,
    IoUringParams,
    IoUringEnterFlags,
    IoUringSetupFlags,
    OwnedFd,
    NO_ENTER_ARG,
)
from std.testing import assert_true, assert_equal


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


def main() raises:
    test_setup()
    print("PASS: test_setup.mojo")
