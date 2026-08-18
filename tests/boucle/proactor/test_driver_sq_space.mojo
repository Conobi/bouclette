"""Test IoUringDriver.sq_space() returns available SQ slot count."""

from std.memory import Pointer
from std.testing import assert_true

from boucle.proactor.completion import Completion
from boucle.drivers.io_uring import IoUringDriver


def test_driver_sq_space() raises:
    var driver = IoUringDriver(sq_entries=16)

    # Fresh driver should have space.
    var space = driver.sq_space()
    assert_true(space > 0)

    # After submitting a NOP, space decreases.
    var cmp = Completion()
    var cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=cmp))
    )
    var space_before = driver.sq_space()
    driver.submit_nop(cmp_ptr)
    var space_after = driver.sq_space()
    assert_true(space_after < space_before)

    # Tick to drain, verify space recovers.
    driver.tick(wait=True)
    var space_final = driver.sq_space()
    assert_true(space_final >= space_before)


def main() raises:
    test_driver_sq_space()
    print("PASS: test_driver_sq_space.mojo")
