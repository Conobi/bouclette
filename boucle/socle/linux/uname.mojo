"""Kernel release string parsing.

`supports()` on the io_uring driver needs the running kernel's
major.minor for the two features the opcode probe cannot see: multishot
recvmsg (6.0) and provided-buffer rings (5.19). compio makes the same
call (`is_kernel_at_least`); a functional trial submission was judged
too heavy for driver construction.

The syscall wrapper that fills a `KernelVersion` from `uname(2)` lives
in this module too; see `kernel_release` and `kernel_version`.
"""

from std.format import Writable, Writer
from std.memory import Pointer

from boucle.socle.linux.raw import syscall, __NR_uname
from boucle.socle.linux.errno import unsafe_decode_none


# struct utsname: sysname, nodename, release, version, machine, domainname,
# each `char[65]` (UTS_LEN 64 plus the terminator), no padding.
comptime UTSNAME_FIELD_LEN = 65
"""Bytes per `utsname` field."""
comptime UTSNAME_SIZE = 6 * UTSNAME_FIELD_LEN
"""Size of `struct utsname` on Linux."""
comptime UTSNAME_RELEASE_OFFSET = 2 * UTSNAME_FIELD_LEN
"""Offset of the `release` field, the third of six."""

comptime _ASCII_ZERO = ord("0")
comptime _ASCII_NINE = ord("9")
comptime _ASCII_DOT = ord(".")


struct KernelVersion(ImplicitlyCopyable, Movable, Writable):
    """A kernel major.minor pair, the granularity feature gates need.

    Fields:
        major: The leading number of the release string.
        minor: The number after the first dot; 0 when absent.
    """

    var major: Int
    var minor: Int

    def __init__(out self, major: Int, minor: Int):
        """Construct a version from its two numbers.

        Args:
            major: The kernel major number.
            minor: The kernel minor number.
        """
        self.major = major
        self.minor = minor

    def at_least(self, major: Int, minor: Int) -> Bool:
        """Return True when this version is `major.minor` or newer.

        Args:
            major: The required major number.
            minor: The required minor number, compared only when the
                   majors are equal.

        Returns:
            True if `self >= major.minor` in lexicographic order.
        """
        if self.major != major:
            return self.major > major
        return self.minor >= minor

    def write_to[W: Writer](self, mut writer: W):
        """Render as `major.minor`."""
        writer.write(self.major, ".", self.minor)


def parse_kernel_release(release: StringSlice) -> KernelVersion:
    """Parse the leading `major.minor` of a `uname -r` string.

    Reads decimal digits into the major until the first dot, then
    digits into the minor until the first non-digit. Anything after that
    (`.0-45-generic`, `-lqx1`) is ignored. Text that does not start with
    a digit parses to `0.0`, which fails every `at_least` gate and so
    turns an unreadable release into "no optional feature".

    Args:
        release: The release string, as `uname(2)` reports it.

    Returns:
        The parsed version.
    """
    var major = 0
    var minor = 0
    var in_minor = False
    for cp in release.codepoints():
        var c = Int(cp.to_u32())
        if c >= _ASCII_ZERO and c <= _ASCII_NINE:
            if in_minor:
                minor = minor * 10 + (c - _ASCII_ZERO)
            else:
                major = major * 10 + (c - _ASCII_ZERO)
        elif c == _ASCII_DOT and not in_minor:
            in_minor = True
        else:
            break
    return KernelVersion(major, minor)


def kernel_release() raises -> String:
    """Return the running kernel's release string via `uname(2)`.

    Returns:
        The NUL-terminated `release` field, without the terminator.

    Raises:
        The negated errno as a string if the syscall fails; on Linux
        `uname` fails only with EFAULT, which a stack buffer rules out.
    """
    var buf = InlineArray[UInt8, UTSNAME_SIZE](fill=0)
    var res = syscall[__NR_uname, Int64](
        Pointer(to=buf).unsafe_bitcast[UInt8]()
    )
    unsafe_decode_none(res)
    var nul = UTSNAME_RELEASE_OFFSET
    var field_end = UTSNAME_RELEASE_OFFSET + UTSNAME_FIELD_LEN
    while nul < field_end and buf[nul] != 0:
        nul += 1
    var release_ptr = buf.unsafe_ptr().unsafe_offset(UTSNAME_RELEASE_OFFSET)
    var slc = StringSlice(
        unsafe_from_utf8=Span[UInt8, origin_of(buf)](
            unsafe_ptr=release_ptr, length=nul - UTSNAME_RELEASE_OFFSET
        )
    )
    return String(slc)


def kernel_version() raises -> KernelVersion:
    """Return the running kernel's major.minor.

    Returns:
        `parse_kernel_release(kernel_release())`.

    Raises:
        Whatever `kernel_release` raises.
    """
    return parse_kernel_release(kernel_release())
