from boucle._sys.linux.mm import (
    mmap_anonymous, munmap, MapFlags, ProtFlags,
)
from std.testing import assert_true


def test_mm() raises:
    # Allocate one page of anonymous memory
    var ptr = mmap_anonymous(
        len=4096,
        prot=ProtFlags.READ | ProtFlags.WRITE,
        flags=MapFlags.PRIVATE,
    )
    assert_true(Int(ptr) != 0)

    # Write and read back via a mutable pointer
    var mut_ptr = ptr.bitcast[UInt8]().unsafe_mut_cast[True]()
    mut_ptr.store(42)
    var val = mut_ptr.load()
    assert_true(val == 42)

    # Unmap
    munmap(unsafe_ptr=ptr, len=4096)


def main() raises:
    test_mm()
    print("PASS: test_mm.mojo")
