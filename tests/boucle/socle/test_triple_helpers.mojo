from boucle.socle import is_linux, is_darwin, is_windows, is_x86_64, is_aarch64
from std.testing import assert_true, assert_false


def test_exactly_one_os_is_true() raises:
    # On the dev/CI box this should be is_linux, but the test is portable.
    var oss = Int(is_linux) + Int(is_darwin) + Int(is_windows)
    assert_true(oss == 1)


def test_at_least_one_arch_is_true() raises:
    var arches = Int(is_x86_64) + Int(is_aarch64)
    assert_true(arches >= 1)


def main() raises:
    test_exactly_one_os_is_true()
    test_at_least_one_arch_is_true()
    print("PASS")
