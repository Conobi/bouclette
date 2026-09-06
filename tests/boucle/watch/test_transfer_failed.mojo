"""The typed failures a recv/send or message future raises from result().

Three reasons exist. IO carries the completion's errno and the buffer
or message that was in flight. NOT_DONE and LOOP_GONE carry EINVAL and
ECANCELED respectively and no buffer: in the first case the loop still
owns it, in the second the loop's destructor abandoned it.
"""

from std.testing import assert_equal, assert_true

from boucle.error import IOError
from boucle.net import Message, MessageResult
from boucle.socle.platform import ECANCELED, EINVAL, ENOTCONN, EPIPE
from boucle.watch import FailureReason, MessageFailed, TransferFailed, TransferResult


def test_failure_reason_compares_and_prints_by_name() raises:
    """FailureReason is Equatable and Writable, rendering its name."""
    assert_true(FailureReason.IO == FailureReason.IO)
    assert_true(FailureReason.IO != FailureReason.NOT_DONE)
    assert_equal(String(FailureReason.IO), "IO")
    assert_equal(String(FailureReason.NOT_DONE), "NOT_DONE")
    assert_equal(String(FailureReason.LOOP_GONE), "LOOP_GONE")


def test_ecanceled_has_a_name() raises:
    """IOError names ECANCELED, which LOOP_GONE renders."""
    assert_equal(String(IOError(positive_errno=ECANCELED)), "ECANCELED (125)")


def test_transfer_failed_io_carries_the_buffer() raises:
    """IO keeps the errno (normalised positive) and hands the buffer back."""
    var buf = List[UInt8](length=4, fill=9)
    var storage = Int(buf.unsafe_ptr())
    var failed = TransferFailed.io(-ENOTCONN, buf^)
    assert_true(failed.reason == FailureReason.IO)
    assert_equal(failed.error.errno_value(), ENOTCONN)
    assert_equal(String(failed), "IO: ENOTCONN (107)")
    var back = failed^.take_buffer()
    assert_true(Bool(back))
    assert_equal(Int(back.value().unsafe_ptr()), storage)


def test_transfer_failed_not_done_and_loop_gone_have_no_buffer() raises:
    """NOT_DONE is EINVAL, LOOP_GONE is ECANCELED; neither returns a buffer."""
    var not_done = TransferFailed.not_done()
    assert_true(not_done.reason == FailureReason.NOT_DONE)
    assert_equal(not_done.error.errno_value(), EINVAL)
    assert_equal(String(not_done), "NOT_DONE: EINVAL (22)")
    assert_true(not Bool(not_done^.take_buffer()))

    var gone = TransferFailed.loop_gone()
    assert_true(gone.reason == FailureReason.LOOP_GONE)
    assert_equal(gone.error.errno_value(), ECANCELED)
    assert_equal(String(gone), "LOOP_GONE: ECANCELED (125)")
    assert_true(not Bool(gone^.take_buffer()))


def test_message_failed_mirrors_transfer_failed() raises:
    """MessageFailed carries a Message on IO and nothing otherwise."""
    var msg = Message(List[UInt8](length=2, fill=1), control_capacity=24)
    var storage = Int(msg.payload().unsafe_ptr())
    var failed = MessageFailed.io(-EPIPE, msg^)
    assert_true(failed.reason == FailureReason.IO)
    assert_equal(failed.error.errno_value(), EPIPE)
    assert_equal(String(failed), "IO: EPIPE (32)")
    var back = failed^.take_message()
    assert_true(Bool(back))
    assert_equal(Int(back.value().payload().unsafe_ptr()), storage)

    assert_true(not Bool(MessageFailed.not_done().take_message()))
    var gone = MessageFailed.loop_gone()
    assert_true(gone.reason == FailureReason.LOOP_GONE)
    assert_true(not Bool(gone^.take_message()))


def test_transfer_result_transferred_clamps_count_above_buffer_length() raises:
    """A count larger than the buffer must not abort transferred(); it
    clamps to the buffer's own length instead."""
    var buf = List[UInt8](length=2, fill=0x41)
    var r = TransferResult(10, buf^)
    assert_equal(r.count, 10, "the raw completion count is preserved")
    assert_equal(len(r.transferred()), 2, "transferred() clamps to the buffer")


def test_transferred_treats_a_negative_count_as_empty() raises:
    """A count below 0 yields an empty span from both result types.

    No loop verb builds a result with a negative count, but a direct
    constructor call can, and the clamp must floor at 0 rather than
    slice to a negative end (an abort under ASSERT=all).
    """
    var empty = TransferResult(-1, List[UInt8]())
    assert_equal(len(empty.transferred()), 0, "negative count, empty buffer")
    var some = TransferResult(-7, List[UInt8](length=4, fill=0x41))
    assert_equal(some.count, -7, "the raw count is preserved")
    assert_equal(len(some.transferred()), 0, "negative count, 4-byte buffer")
    var msg = MessageResult(-1, Message(List[UInt8](length=4, fill=0)), 0)
    assert_equal(len(msg.transferred()), 0, "negative count on a message")


def main() raises:
    test_failure_reason_compares_and_prints_by_name()
    test_ecanceled_has_a_name()
    test_transfer_failed_io_carries_the_buffer()
    test_transfer_failed_not_done_and_loop_gone_have_no_buffer()
    test_message_failed_mirrors_transfer_failed()
    test_transfer_result_transferred_clamps_count_above_buffer_length()
    test_transferred_treats_a_negative_count_as_empty()
    print("PASS: test_transfer_failed.mojo")
