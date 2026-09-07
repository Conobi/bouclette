"""Test FileTransferResult and FileTransferFailed."""

from std.testing import assert_true
from boucle.buffer import AlignedBuffer
from boucle.watch.transfer import (
    FileTransferResult,
    FileTransferFailed,
    FailureReason,
)


def test_result_count_and_span() raises:
    """FileTransferResult returns count and a span of transferred bytes."""
    var buf = AlignedBuffer(capacity=32, fill=0xAA)
    var r = FileTransferResult(count=10, buf=buf^)
    assert_true(r.count() == 10, "wrong count")
    var s = r.transferred()
    assert_true(len(s) == 10, "span wrong length")
    assert_true(s[0] == 0xAA, "span wrong content")


def test_result_take_buffer() raises:
    """FileTransferResult.take_buffer recovers the AlignedBuffer."""
    var buf = AlignedBuffer(capacity=16, alignment=512)
    buf.append(0x42)
    var r = FileTransferResult(count=1, buf=buf^)
    var back = r^.take_buffer()
    assert_true(back.alignment() == 512, "alignment lost")
    assert_true(len(back) == 1, "data lost")


def test_failed_io_with_buffer() raises:
    """FileTransferFailed with IO reason carries the buffer."""
    var buf = AlignedBuffer(capacity=8)
    buf.append(0xFF)
    var f = FileTransferFailed.io(-5, buf^)
    assert_true(f.reason == FailureReason.IO, "wrong reason")
    var back = f^.take_buffer()
    assert_true(Bool(back), "IO should have buffer")


def test_failed_not_done() raises:
    """FileTransferFailed with NOT_DONE has no buffer."""
    var f = FileTransferFailed.not_done()
    assert_true(f.reason == FailureReason.NOT_DONE, "wrong reason")
    var back = f^.take_buffer()
    assert_true(not Bool(back), "NOT_DONE should have no buffer")


def test_failed_loop_gone() raises:
    """FileTransferFailed with LOOP_GONE has no buffer."""
    var f = FileTransferFailed.loop_gone()
    assert_true(f.reason == FailureReason.LOOP_GONE, "wrong reason")


def main() raises:
    test_result_count_and_span()
    print("PASS: FileTransferResult count and span")
    test_result_take_buffer()
    print("PASS: take_buffer")
    test_failed_io_with_buffer()
    print("PASS: FileTransferFailed IO with buffer")
    test_failed_not_done()
    print("PASS: FileTransferFailed NOT_DONE")
    test_failed_loop_gone()
    print("PASS: FileTransferFailed LOOP_GONE")
