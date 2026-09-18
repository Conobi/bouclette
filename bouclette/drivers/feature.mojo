"""Optional driver capabilities a caller can ask about before submitting.

A completion driver answers `supports(feature)` from facts gathered at
construction. The epoll completion driver emulates every feature in
userspace and answers True to all of them; the io_uring driver answers
from its opcode probe, the kernel version and the setup feature flags.
"""

from std.format import Writable, Writer


@fieldwise_init
struct DriverFeature(TrivialRegisterPassable, Equatable, Writable):
    """Identifies one optional capability of a completion driver.

    - `MULTISHOT_RECVMSG`: one submission delivers many datagrams into
      provided buffers (io_uring 6.0; emulated on epoll).
    - `BUFFER_RING`: a registered provided-buffer ring the kernel picks
      from (io_uring 5.19; emulated on epoll).
    - `TIMEOUT_ARG`: a bounded wait is expressed in the enter call
      itself (`IORING_FEAT_EXT_ARG`, io_uring 5.11) rather than through
      a sentinel timeout submission. Never affects backend selection.
    - `FILE_READ`: async pread via io_uring or worker pool.
    - `FILE_WRITE`: async pwrite via io_uring or worker pool.
    - `FILE_FSYNC`: async fsync/fdatasync via io_uring or worker pool.
    """

    comptime MULTISHOT_RECVMSG = Self(0)
    comptime BUFFER_RING = Self(1)
    comptime TIMEOUT_ARG = Self(2)
    comptime FILE_READ = Self(3)
    comptime FILE_WRITE = Self(4)
    comptime FILE_FSYNC = Self(5)

    var id: UInt8

    @always_inline("nodebug")
    def __is__(self, rhs: Self) -> Bool:
        """Identity: same feature id."""
        return self.id == rhs.id

    @always_inline("nodebug")
    def __isnot__(self, rhs: Self) -> Bool:
        """Negated identity."""
        return self.id != rhs.id

    @always_inline("nodebug")
    def __eq__(self, rhs: Self) -> Bool:
        """Equality: same feature id."""
        return self.id == rhs.id

    @always_inline("nodebug")
    def __ne__(self, rhs: Self) -> Bool:
        """Inequality."""
        return self.id != rhs.id

    def write_to[W: Writer](self, mut writer: W):
        """Write the feature name."""
        if self.id == Self.MULTISHOT_RECVMSG.id:
            writer.write("multishot_recvmsg")
        elif self.id == Self.BUFFER_RING.id:
            writer.write("buffer_ring")
        elif self.id == Self.TIMEOUT_ARG.id:
            writer.write("timeout_arg")
        elif self.id == Self.FILE_READ.id:
            writer.write("file_read")
        elif self.id == Self.FILE_WRITE.id:
            writer.write("file_write")
        elif self.id == Self.FILE_FSYNC.id:
            writer.write("file_fsync")
        else:
            writer.write("unknown(", self.id, ")")
