"""Test IoUringDriver.sq_space() returns available SQ slot count."""

from std.memory import UnsafePointer
from std.testing import assert_true

from boucle.proactor.completion import Completion
from boucle.drivers.io_uring import IoUringDriver


def main() raises:
    var driver = IoUringDriver(sq_entries=16)

    # Fresh driver should have space.
    var space = driver.sq_space()
    assert_true(space > 0)

    # After submitting a NOP, space decreases.
    var cmp = Completion()
    var cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=cmp))
    )
    var space_before = driver.sq_space()
    driver.submit_nop(cmp_ptr)
    var space_after = driver.sq_space()
    assert_true(space_after < space_before)

    # Tick to drain, verify space recovers.
    driver.tick(wait=True)
    var space_final = driver.sq_space()
    assert_true(space_final >= space_before)

    print("PASS: test_driver_sq_space")
