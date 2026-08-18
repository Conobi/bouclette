from boucle.buffer import IOBuffer
from std.testing import assert_equal, assert_true


def test_buffer() raises:
    var data = List[UInt8](length=64, fill=UInt8(0))
    var buf = IOBuffer(data)

    assert_equal(buf.len, UInt(64))
    assert_true(Int(buf.unsafe_ptr) != 0)

    var ptr = Pointer[Int8, ImmStaticOrigin](
        unsafe_from_address=Int(data.unsafe_ptr())
    )
    var buf2 = IOBuffer(unsafe_ptr=ptr, len=32)
    assert_equal(buf2.len, UInt(32))


def main() raises:
    test_buffer()
    print("PASS: test_buffer.mojo")
