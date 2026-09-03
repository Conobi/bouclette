"""Behavioural tests for the anonymous-mapping flags of `Region`.

`Region.__init__[is_shared](len=..., flags=...)` backs io_uring rings that
the user allocates for `IORING_SETUP_NO_MMAP`. It must honour
`MAP_POPULATE` and the caller-supplied flags on BOTH the shared and private
paths. Residency is observed through `mincore(2)`: after a populated
mapping every page must report its low bit set.
"""
from boucle.socle.linux.io_uring.mm import Region
from boucle.socle.linux.mm import (
    mincore,
    mmap_anonymous,
    munmap,
    get_page_size,
    MapFlags,
    ProtFlags,
)
from std.pathlib import Path
from std.testing import assert_true, assert_equal


def _resident_pages(region: Region) raises -> Int:
    """Counts the pages of `region` that `mincore(2)` reports as resident.

    A private scratch page holds the `mincore` vector (one byte per page),
    which is enough for any region of at most `page_size * page_size` bytes.

    Args:
        region: The mapping to inspect.

    Returns:
        Number of pages whose residency bit is set.
    """
    var page_size = get_page_size()
    var n_pages = (region.len + page_size - 1) // page_size
    assert_true(n_pages <= page_size, "mincore vector must fit one page")
    var vec = mmap_anonymous(
        len=page_size,
        prot=ProtFlags.READ | ProtFlags.WRITE,
        flags=MapFlags.PRIVATE,
    )
    var vec_u8 = vec.unsafe_bitcast[UInt8]()
    mincore(unsafe_ptr=region.unsafe_ptr(), len=region.len, vec=vec_u8)
    var resident = 0
    for i in range(n_pages):
        if vec_u8.unsafe_offset(i).unsafe_load() & 1:
            resident += 1
    munmap(unsafe_ptr=vec, len=page_size)
    return resident


def test_private_region_with_populate_is_resident_immediately() raises:
    """Control: the private path already applied MAP_POPULATE."""
    var page_size = get_page_size()
    var n_pages = 8
    var region = Region.private(
        len=page_size * UInt(n_pages), flags=MapFlags()
    )
    assert_equal(
        _resident_pages(region),
        n_pages,
        "private Region must be fully resident right after construction",
    )


def test_shared_region_with_populate_is_resident_immediately() raises:
    """The default (shared) path must apply MAP_POPULATE too.

    Regression: the conditional in `Region.__init__` bound loosest, so
    `is_shared=True` dropped POPULATE and the caller's flags and mapped
    plain MAP_SHARED|MAP_ANONYMOUS memory that faulted in lazily.
    """
    var page_size = get_page_size()
    var n_pages = 8
    var region = Region(len=page_size * UInt(n_pages), flags=MapFlags())
    assert_equal(
        _resident_pages(region),
        n_pages,
        "shared Region must be fully resident right after construction",
    )


def test_shared_region_hugetlb_request_succeeds_without_reserved_hugepages() raises:
    """A HUGETLB request must not fail when no huge pages are reserved.

    `MemoryMapping` asks for HUGETLB|HUGE_2MB for rings larger than a
    page. Huge pages are an optimisation, never a requirement: when the
    kernel refuses (`nr_hugepages` is 0 by default) the Region must fall
    back to regular pages and still be fully populated.
    """
    comptime HUGE_PAGE_SIZE = 1 << 21
    var page_size = get_page_size()
    var region = Region(
        len=UInt(HUGE_PAGE_SIZE), flags=MapFlags.HUGETLB | MapFlags.HUGE_2MB
    )
    assert_equal(
        _resident_pages(region),
        HUGE_PAGE_SIZE // Int(page_size),
        "huge-page-sized shared Region must be fully resident",
    )


def _reserved_hugepages() raises -> Int:
    """Reads `vm.nr_hugepages`, the number of huge pages the kernel has reserved.

    Returns:
        The integer value of `/proc/sys/vm/nr_hugepages`.
    """
    return Int(Path("/proc/sys/vm/nr_hugepages").read_text().strip())


def test_shared_region_hugetlb_fallback_uses_page_rounded_length() raises:
    """The regular-page retry must map only what the ring needs.

    `MemoryMapping` rounds a ring larger than a page up to 2 MiB so the
    HUGETLB attempt is well-formed, but that length is a huge-page artefact:
    a ring that needs 3 pages must not pin 512 populated pages when the
    kernel refuses the huge mapping. The caller passes the page-rounded
    needed size as `fallback_len`; after fallback both `Region.len` and the
    resident page count must equal it, not 2 MiB.

    Skipped (with a printed `SKIP:` line) when `vm.nr_hugepages` is
    non-zero: the first mmap then succeeds and the fallback path never
    runs, so nothing about its length can be observed.
    """
    var reserved = _reserved_hugepages()
    if reserved != 0:
        print(
            "SKIP: test_shared_region_hugetlb_fallback_uses_page_rounded_length"
            " (vm.nr_hugepages =",
            reserved,
            "so the HUGETLB mmap succeeds and no fallback happens)",
        )
        return
    comptime HUGE_PAGE_SIZE = 1 << 21
    var page_size = get_page_size()
    var n_pages = 3
    var needed_len = page_size * UInt(n_pages)
    var region = Region(
        len=UInt(HUGE_PAGE_SIZE),
        flags=MapFlags.HUGETLB | MapFlags.HUGE_2MB,
        fallback_len=needed_len,
    )
    assert_equal(
        region.len,
        needed_len,
        "fallback Region must be exactly the page-rounded needed length",
    )
    assert_equal(
        _resident_pages(region),
        n_pages,
        "fallback Region must populate only the pages the ring needs",
    )


def main() raises:
    test_private_region_with_populate_is_resident_immediately()
    test_shared_region_with_populate_is_resident_immediately()
    test_shared_region_hugetlb_request_succeeds_without_reserved_hugepages()
    test_shared_region_hugetlb_fallback_uses_page_rounded_length()
    print("PASS: test_region_flags.mojo")
