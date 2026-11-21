"""TempDir is removed on both the raise path and the success path."""

from std.os.path import isdir
from std.testing import assert_true
from tests._test_util import TempDir


def _make_and_raise(mut seen: List[String]) raises:
    var td = TempDir()
    seen.append(td.dir)
    assert_true(isdir(td.dir), "dir exists while td is live")
    var f = open(td.path("a.txt"), "w")
    f.write("x")
    f.close()
    assert_true(False, "forced failure")
    _ = td^


def test_tempdir_removed_on_raise() raises:
    var seen = List[String]()
    var raised = False
    try:
        _make_and_raise(seen)
    except:
        raised = True
    assert_true(raised, "helper raised")
    assert_true(not isdir(seen[0]), "TempDir removed on raise path")


def test_tempdir_removed_on_success() raises:
    var td = TempDir()
    var path = td.dir
    var f = open(td.path("a.txt"), "w")
    f.write("x")
    f.close()
    assert_true(isdir(path), "live before end")
    _ = td^
    assert_true(not isdir(path), "removed after td^")


def main() raises:
    test_tempdir_removed_on_raise()
    print("PASS: tempdir removed on raise")
    test_tempdir_removed_on_success()
    print("PASS: tempdir removed on success")
