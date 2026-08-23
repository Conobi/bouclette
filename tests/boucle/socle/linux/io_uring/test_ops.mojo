from boucle.socle.linux.io_uring import IoUring
from boucle.socle.linux.io_uring.op import Read, Write
from std.ffi import external_call
from std.testing import assert_equal, assert_true


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var ring = IoUring[](sq_entries=4)
        ring^.__deinit__()
        return True
    except:
        return False


def test_ops() raises:
    # Create a pipe
    var pipefd = Array[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        Pointer(to=pipefd).unsafe_bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd = pipefd[0]
    var write_fd = pipefd[1]

    var ring = IoUring[](sq_entries=8)

    # Write "hello" via io_uring
    var msg = String("hello")
    var msg_ptr = Pointer[Int8, ImmStaticOrigin](
        unsafe_from_address=Int(msg.unsafe_ptr())
    )
    var sq = ring.sq()
    _ = Write(sq.__next__(), write_fd, msg_ptr, UInt(5)).user_data(1)
    _ = ring.submit_and_wait(wait_nr=1)

    var cq = ring.cq(wait_nr=0)
    assert_true(Bool(cq))
    var cqe = cq.__next__()
    assert_equal(cqe.user_data, UInt64(1))
    assert_equal(cqe.res, Int32(5))
    cq^.__deinit__()

    # Read back via io_uring
    var buf = List[UInt8](length=16, fill=0)
    var buf_ptr = Pointer[Int8, ImmStaticOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    sq = ring.sq()
    _ = Read(sq.__next__(), read_fd, buf_ptr, UInt(16)).user_data(2)
    _ = ring.submit_and_wait(wait_nr=1)

    cq = ring.cq(wait_nr=0)
    assert_true(Bool(cq))
    cqe = cq.__next__()
    assert_equal(cqe.user_data, UInt64(2))
    assert_equal(cqe.res, Int32(5))  # 5 bytes read
    cq^.__deinit__()

    # Cleanup
    _ = external_call["close", Int32](read_fd)
    _ = external_call["close", Int32](write_fd)


def main() raises:
    if not _has_io_uring():
        print("SKIP: io_uring not available")
        return
    test_ops()
    print("PASS: test_ops.mojo")
