"""DriverFeature is a closed enum with identity comparison and a name."""

from std.testing import assert_equal, assert_false, assert_true

from boucle.drivers import DriverFeature


def test_identity() raises:
    """`is` and `==` agree; distinct features differ."""
    assert_true(DriverFeature.MULTISHOT_RECVMSG is DriverFeature.MULTISHOT_RECVMSG)
    assert_true(DriverFeature.BUFFER_RING == DriverFeature.BUFFER_RING)
    assert_true(DriverFeature.TIMEOUT_ARG is not DriverFeature.BUFFER_RING)
    assert_false(DriverFeature.MULTISHOT_RECVMSG == DriverFeature.TIMEOUT_ARG)


def test_names() raises:
    """Each feature renders by name, so a failed gate reads in a log."""
    assert_equal(String(DriverFeature.MULTISHOT_RECVMSG), "multishot_recvmsg")
    assert_equal(String(DriverFeature.BUFFER_RING), "buffer_ring")
    assert_equal(String(DriverFeature.TIMEOUT_ARG), "timeout_arg")


def main() raises:
    test_identity()
    test_names()
    print("PASS: test_driver_feature.mojo")
