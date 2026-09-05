"""`buffer_id` and `has_more` decode completion flags without private imports.

The encoding is io_uring's CQE flag layout, which the epoll driver also
emits for multishot deliveries: bit 0 says a provided buffer was used,
bits 16..31 carry its id, bit 1 says the operation stays armed.
"""

from std.testing import assert_equal, assert_false, assert_true

from boucle.proactor import buffer_id, has_more


def test_buffer_id_present() raises:
    """Bit 0 set: the id is the high 16 bits."""
    var flags = UInt32(1) | (UInt32(5) << 16)
    var id = buffer_id(flags)
    assert_true(Bool(id), "buffer id must be present")
    assert_equal(Int(id.value()), 5)


def test_buffer_id_max() raises:
    """The full 16-bit range decodes."""
    var flags = UInt32(1) | (UInt32(0xFFFF) << 16)
    assert_equal(Int(buffer_id(flags).value()), 0xFFFF)


def test_buffer_id_absent() raises:
    """Bit 0 clear: no buffer, whatever the high bits say."""
    assert_false(Bool(buffer_id(UInt32(0))))
    assert_false(Bool(buffer_id(UInt32(5) << 16)))
    assert_false(Bool(buffer_id(UInt32(2))))


def test_has_more() raises:
    """Bit 1 is the multishot continuation flag."""
    assert_true(has_more(UInt32(2)))
    assert_true(has_more(UInt32(3)))
    assert_false(has_more(UInt32(1)))
    assert_false(has_more(UInt32(0)))


def main() raises:
    test_buffer_id_present()
    test_buffer_id_max()
    test_buffer_id_absent()
    test_has_more()
    print("PASS: test_completion_flags.mojo")
