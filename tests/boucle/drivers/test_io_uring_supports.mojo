"""IoUringDriver.supports() agrees with independent reads of the kernel.

The expected answers are computed here from a second ring: an opcode
probe, the setup feature flags and uname. The driver must reach the
same conclusions from its own reads.
"""

from std.testing import assert_equal, assert_false, assert_true

from boucle.drivers import DriverFeature
from boucle.drivers.io_uring import IoUringDriver, _features_from
from boucle.socle.linux.io_uring import (
    IoUring,
    IoUringFeatureFlags,
    IoUringOp,
    IoUringParams,
    IoUringProbe,
    IoUringRegisterOp,
    IoUringSetupFlags,
)
from boucle.socle.linux.uname import kernel_version, KernelVersion


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel.

    Constructs a bare ring rather than the driver under test, so a
    setup failure here (ENOSYS on a kernel without io_uring) is never
    confused with a bug in `IoUringDriver.__init__` itself.
    """
    try:
        var ring = IoUring[](sq_entries=UInt32(4))
        ring^.__deinit__()
        return True
    except:
        return False


def test_supports_matches_kernel() raises:
    """Each feature answer matches its independently computed expectation."""
    var params = IoUringParams()
    var ring = IoUring[](sq_entries=UInt32(4), params=params)
    var probe = IoUringProbe()
    var recvmsg_ok: Bool
    try:
        _ = ring.register(
            probe.as_register_arg(
                unsafe_opcode=IoUringRegisterOp.REGISTER_PROBE
            )
        )
        recvmsg_ok = probe.is_supported(IoUringOp.RECVMSG)
    except:
        # Catches any register() failure, not only a pre-5.6 kernel
        # missing REGISTER_PROBE (EINVAL).
        recvmsg_ok = False
    var kv = kernel_version()
    var expect_multishot = recvmsg_ok and kv.at_least(6, 0)
    var expect_bufring = kv.at_least(5, 19)
    var expect_timeout_arg = Bool(
        params.features & IoUringFeatureFlags.EXT_ARG
    )
    ring^.__deinit__()

    var driver = IoUringDriver(capacity=4)
    assert_equal(
        driver.supports(DriverFeature.MULTISHOT_RECVMSG), expect_multishot
    )
    assert_equal(driver.supports(DriverFeature.BUFFER_RING), expect_bufring)
    assert_equal(
        driver.supports(DriverFeature.TIMEOUT_ARG), expect_timeout_arg
    )
    print(
        "  multishot_recvmsg=", expect_multishot,
        " buffer_ring=", expect_bufring,
        " timeout_arg=", expect_timeout_arg,
        " kernel=", kv,
    )


def test_supports_survives_move() raises:
    """The answers travel with the driver when it is moved.

    Moves into `List.append` rather than `var moved = driver^`: the
    latter the compiler may lower as a rename of the same storage
    rather than a genuine move-constructor call.
    """
    var driver = IoUringDriver(capacity=4)
    var before = driver.supports(DriverFeature.TIMEOUT_ARG)
    var movers = List[IoUringDriver]()
    movers.append(driver^)
    assert_equal(movers[0].supports(DriverFeature.TIMEOUT_ARG), before)


def test_setup_carries_no_sqarray() raises:
    """The driver requests IORING_SETUP_NO_SQARRAY at ring setup.

    The old construction path (`IoUring[](sq_entries=...)`) went
    through `Params()`, whose default flags include NO_SQARRAY. The
    driver builds its own `IoUringParams` directly, so it must set the
    flag itself or the ring silently falls back to the legacy SQ-array
    layout.
    """
    var driver = IoUringDriver(capacity=4)
    assert_true(
        Bool(driver.setup_flags() & IoUringSetupFlags.NO_SQARRAY),
        "driver must request IORING_SETUP_NO_SQARRAY at setup",
    )


def test_features_from_degrades_on_unreadable_kernel() raises:
    """An unreadable kernel release fails every version gate.

    `_features_from` is the pure function `__init__` funnels its
    version-gated answers through. Driving it directly with
    `KernelVersion(0, 0)` exercises the degrade-on-failure path a real
    `uname(2)` failure cannot be forced to hit in a unit test.
    """
    var no_features = IoUringFeatureFlags()
    var ext_arg = IoUringFeatureFlags.EXT_ARG

    var unreadable = _features_from(KernelVersion(0, 0), True, ext_arg)
    assert_false(
        unreadable.multishot_recvmsg, "0.0 must fail the 6.0 gate"
    )
    assert_false(unreadable.buffer_ring, "0.0 must fail the 5.19 gate")
    assert_true(
        unreadable.timeout_arg, "timeout_arg only depends on features"
    )

    var pre_multishot = _features_from(KernelVersion(5, 19), True, no_features)
    assert_false(
        pre_multishot.multishot_recvmsg, "5.19 predates multishot recvmsg"
    )
    assert_true(pre_multishot.buffer_ring, "5.19 introduces buffer rings")
    assert_false(pre_multishot.timeout_arg)

    var at_multishot = _features_from(KernelVersion(6, 0), True, no_features)
    assert_true(at_multishot.multishot_recvmsg, "6.0 has multishot recvmsg")
    assert_true(at_multishot.buffer_ring, "6.0 is newer than 5.19")

    var unprobed = _features_from(KernelVersion(6, 0), False, no_features)
    assert_false(
        unprobed.multishot_recvmsg,
        "a failed probe blocks multishot recvmsg even on 6.0+",
    )


def test_setup_carries_taskrun_flags() raises:
    """The driver requests SINGLE_ISSUER, DEFER_TASKRUN, COOP_TASKRUN and TASKRUN_FLAG.

    They make the constructing thread the ring's only issuer and defer
    task work to its GETEVENTS enters. The kernel rejects `DEFER_TASKRUN`
    without `SINGLE_ISSUER`, so the four travel together; a lost flag
    silently falls back to eager task-work delivery, which no other test
    can observe.
    """
    var driver = IoUringDriver(capacity=4)
    var flags = driver.setup_flags()
    assert_true(
        Bool(flags & IoUringSetupFlags.SINGLE_ISSUER),
        "driver must request IORING_SETUP_SINGLE_ISSUER at setup",
    )
    assert_true(
        Bool(flags & IoUringSetupFlags.DEFER_TASKRUN),
        "driver must request IORING_SETUP_DEFER_TASKRUN at setup",
    )
    assert_true(
        Bool(flags & IoUringSetupFlags.COOP_TASKRUN),
        "driver must request IORING_SETUP_COOP_TASKRUN at setup",
    )
    assert_true(
        Bool(flags & IoUringSetupFlags.TASKRUN_FLAG),
        "driver must request IORING_SETUP_TASKRUN_FLAG at setup",
    )
    assert_true(
        Bool(flags & IoUringSetupFlags.NO_SQARRAY),
        "NO_SQARRAY must survive next to the task-work flags",
    )


def main() raises:
    # Pure: does not touch the kernel, so it runs even without io_uring.
    test_features_from_degrades_on_unreadable_kernel()

    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_supports_matches_kernel()
    test_supports_survives_move()
    test_setup_carries_no_sqarray()
    test_setup_carries_taskrun_flags()
    print("PASS: test_io_uring_supports.mojo")
