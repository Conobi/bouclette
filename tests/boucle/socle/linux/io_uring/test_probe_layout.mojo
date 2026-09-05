"""Golden layout and live behaviour of the IORING_REGISTER_PROBE reply.

struct io_uring_probe_op { __u8 op; __u8 resv; __u16 flags; __u32 resv2; }
is 8 bytes. struct io_uring_probe { __u8 last_op; __u8 ops_len; __u16 resv;
__u32 resv2[3]; struct io_uring_probe_op ops[]; } is a 16-byte header;
with 256 trailing entries the register argument is 16 + 256 * 8 bytes.
"""

from std.sys.info import size_of
from std.testing import assert_equal, assert_false, assert_true

from boucle.socle.linux.io_uring import (
    IoUring,
    IoUringOp,
    IoUringProbe,
    IoUringProbeOp,
    IoUringRegisterOp,
)
from boucle.socle.linux.raw import IO_URING_OP_SUPPORTED, IORING_OP_RECVMSG


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var ring = IoUring[](sq_entries=4)
        ring^.__deinit__()
        return True
    except:
        return False


def test_probe_layout() raises:
    """Sizes match the kernel UAPI with 256 op entries."""
    assert_equal(size_of[IoUringProbeOp](), 8)
    assert_equal(size_of[IoUringProbe](), 16 + 256 * 8)
    assert_equal(Int(IO_URING_OP_SUPPORTED), 1)
    var op = IoUringProbeOp()
    assert_equal(Int(op.op), 0)
    assert_equal(Int(op.flags), 0)


def test_probe_default_supports_nothing() raises:
    """Before registration every opcode reads as unsupported."""
    var probe = IoUringProbe()
    assert_false(probe.is_supported(IoUringOp.NOP))
    assert_false(probe.is_supported(IoUringOp.RECVMSG))


def test_live_probe() raises:
    """A real REGISTER_PROBE fills the table; NOP is always supported."""
    var ring = IoUring[](sq_entries=4)
    var probe = IoUringProbe()
    var arg = probe.as_register_arg(
        unsafe_opcode=IoUringRegisterOp.REGISTER_PROBE
    )
    var res = ring.register(arg)
    assert_equal(Int(res), 0)
    assert_true(Int(probe.last_op) >= IORING_OP_RECVMSG, "last_op too small")
    assert_equal(Int(probe.ops_len), Int(probe.last_op) + 1)
    assert_true(probe.is_supported(IoUringOp.NOP), "NOP must be supported")
    assert_true(
        probe.is_supported(IoUringOp.RECVMSG), "RECVMSG must be supported"
    )
    assert_equal(Int(probe.ops[10].op), 10, "ops[i].op is the opcode i")
    assert_false(
        probe.is_supported(IoUringOp(unsafe_id=UInt8(250))),
        "an opcode past last_op is unsupported",
    )
    ring^.__deinit__()


def main() raises:
    test_probe_layout()
    test_probe_default_supports_nothing()
    if _has_io_uring():
        test_live_probe()
    else:
        print("SKIP: io_uring not available for the live probe")
    print("PASS: test_probe_layout.mojo")
