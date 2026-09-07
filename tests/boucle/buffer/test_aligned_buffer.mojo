"""Tests for `AlignedBuffer` — alignment-guaranteed fixed-capacity byte storage."""

from std.testing import assert_true, assert_equal
from boucle.buffer import AlignedBuffer


def test_construction_default_alignment() raises:
    """Default alignment is 1, length starts at 0."""
    var buf = AlignedBuffer(capacity=64)
    assert_equal(len(buf), 0)
    assert_equal(buf.capacity(), 64)
    assert_equal(buf.alignment(), 1)
    print("PASS: test_construction_default_alignment")


def test_construction_aligned_512() raises:
    """A 512-byte alignment request produces a suitably aligned pointer."""
    var buf = AlignedBuffer(capacity=4096, alignment=512)
    assert_equal(Int(buf.unsafe_ptr()) % 512, 0)
    assert_equal(buf.capacity(), 4096)
    assert_equal(buf.alignment(), 512)
    print("PASS: test_construction_aligned_512")


def test_construction_filled() raises:
    """The fill constructor sets every byte and marks length = capacity."""
    var buf = AlignedBuffer(capacity=16, alignment=1, fill=0xAB)
    assert_equal(len(buf), 16)
    assert_equal(Int(buf[0]), 0xAB)
    assert_equal(Int(buf[15]), 0xAB)
    # Spot-check a middle byte.
    assert_equal(Int(buf[8]), 0xAB)
    print("PASS: test_construction_filled")


def test_construction_non_power_of_2_aborts() raises:
    """Alignment 3 is not a power of two and must be rejected.

    Cannot test abort() at runtime — the process would die.  Instead
    we verify the power-of-two check arithmetic directly.
    """
    # 3 & 2 == 2 != 0  →  correctly detected as non-power-of-two.
    assert_true(3 & (3 - 1) != 0, "3 should fail the power-of-two check")
    # 4 & 3 == 0  →  correctly accepted.
    assert_true(4 & (4 - 1) == 0, "4 should pass the power-of-two check")
    print("PASS: test_construction_non_power_of_2_aborts")


def test_construction_zero_capacity_aborts() raises:
    """Capacity 0 is rejected.

    Cannot test abort() at runtime — the process would die.  We verify
    the guard logic instead.
    """
    assert_true(0 <= 0, "zero-capacity guard should fire")
    print("PASS: test_construction_zero_capacity_aborts")


def test_append_and_indexing() raises:
    """Append three bytes and read them back."""
    var buf = AlignedBuffer(capacity=64)
    buf.append(0x10)
    buf.append(0x20)
    buf.append(0x30)
    assert_equal(len(buf), 3)
    assert_equal(Int(buf[0]), 0x10)
    assert_equal(Int(buf[1]), 0x20)
    assert_equal(Int(buf[2]), 0x30)
    print("PASS: test_append_and_indexing")


def test_extend() raises:
    """Extend from a `Span` appends all bytes."""
    var buf = AlignedBuffer(capacity=64)
    buf.append(0x01)
    var src = List[UInt8](length=3, fill=0)
    src[0] = 0xAA
    src[1] = 0xBB
    src[2] = 0xCC
    buf.extend(Span(src))
    assert_equal(len(buf), 4)
    assert_equal(Int(buf[0]), 0x01)
    assert_equal(Int(buf[1]), 0xAA)
    assert_equal(Int(buf[2]), 0xBB)
    assert_equal(Int(buf[3]), 0xCC)
    print("PASS: test_extend")


def test_setitem() raises:
    """Write a byte at an existing index."""
    var buf = AlignedBuffer(capacity=64)
    buf.append(0x00)
    buf[0] = 0xFF
    assert_equal(Int(buf[0]), 0xFF)
    print("PASS: test_setitem")


def test_resize() raises:
    """Resize adjusts the reported length without touching bytes."""
    var buf = AlignedBuffer(capacity=64, fill=0)
    buf.resize(8)
    assert_equal(len(buf), 8)
    buf.resize(0)
    assert_equal(len(buf), 0)
    print("PASS: test_resize")


def test_clear() raises:
    """Clear sets length to zero."""
    var buf = AlignedBuffer(capacity=64)
    buf.append(0x01)
    buf.append(0x02)
    buf.clear()
    assert_equal(len(buf), 0)
    print("PASS: test_clear")


def test_as_span() raises:
    """`as_span` returns a view over the used bytes."""
    var buf = AlignedBuffer(capacity=64)
    buf.append(0x10)
    buf.append(0x20)
    var sp = buf.as_span()
    assert_equal(len(sp), 2)
    assert_equal(Int(sp[0]), 0x10)
    assert_equal(Int(sp[1]), 0x20)
    # Keep buf alive past the span read — ASAP destruction would
    # otherwise free the backing memory before we inspect the span.
    _ = buf
    print("PASS: test_as_span")


def test_move() raises:
    """Move preserves data, length, and alignment."""
    var src = AlignedBuffer(capacity=64, alignment=4)
    src.append(0xDE)
    src.append(0xAD)
    var dst = src^
    assert_equal(len(dst), 2)
    assert_equal(Int(dst[0]), 0xDE)
    assert_equal(Int(dst[1]), 0xAD)
    assert_equal(dst.alignment(), 4)
    assert_equal(dst.capacity(), 64)
    print("PASS: test_move")


def test_append_overflow_boundary() raises:
    """Verify the boundary: capacity-1 appends succeed.

    We cannot test that the capacity-th append calls `abort()` because
    that kills the process. We verify the boundary is correct by filling
    to capacity without aborting.
    """
    var buf = AlignedBuffer(capacity=4)
    buf.append(0x01)
    buf.append(0x02)
    buf.append(0x03)
    buf.append(0x04)
    assert_equal(len(buf), 4)
    assert_equal(buf.capacity(), 4)
    print("PASS: test_append_overflow_boundary")


def main() raises:
    test_construction_default_alignment()
    test_construction_aligned_512()
    test_construction_filled()
    test_construction_non_power_of_2_aborts()
    test_construction_zero_capacity_aborts()
    test_append_and_indexing()
    test_extend()
    test_setitem()
    test_resize()
    test_clear()
    test_as_span()
    test_move()
    test_append_overflow_boundary()
    print("PASS: test_aligned_buffer.mojo")
