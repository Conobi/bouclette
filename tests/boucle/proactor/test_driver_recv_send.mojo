"""Integration test: submit_recv and submit_send via IoUringDriver."""

from std.ffi import external_call
from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc
from std.testing import assert_true

from boucle.proactor.completion import Completion
from boucle.drivers.io_uring import IoUringDriver
from boucle.handle import RawHandle


struct ResultTracker:
    """Records callback invocations for recv/send completions."""

    var result: Int32
    var flags: UInt32
    var fired: Bool

    def __init__(out self):
        """Construct a zeroed tracker."""
        self.result = Int32(0)
        self.flags = UInt32(0)
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: UnsafePointer[NoneType, MutAnyOrigin],
        result: Int32,
        flags: UInt32,
    ):
        """Callback that records the completion result."""
        var self_ptr = UnsafePointer[ResultTracker, MutAnyOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].flags = flags
        self_ptr[].fired = True


def main() raises:
    """Run recv/send integration test."""
    # Create a connected socket pair (AF_UNIX=1, SOCK_STREAM=1).
    var fds = alloc[Int32](2)
    var sp_res = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1),  # SOCK_STREAM
        Int32(0),  # protocol
        fds,
    )
    if Int(sp_res) != 0:
        var en = external_call[
            "__errno_location", UnsafePointer[Int32, MutAnyOrigin]
        ]()
        raise String("socketpair failed, errno=") + String(Int(en[]))

    var fd_a: RawHandle = fds[]
    var fd_b: RawHandle = (fds + 1)[]
    fds.free()

    # Set up driver.
    var driver = IoUringDriver(sq_entries=16)

    # Prepare send buffer: "hello" (5 bytes).
    var send_buf = alloc[UInt8](5)
    send_buf[] = UInt8(104)        # 'h'
    (send_buf + 1)[] = UInt8(101)  # 'e'
    (send_buf + 2)[] = UInt8(108)  # 'l'
    (send_buf + 3)[] = UInt8(108)  # 'l'
    (send_buf + 4)[] = UInt8(111)  # 'o'

    # Prepare recv buffer: 16 bytes zeroed.
    var recv_buf = alloc[UInt8](16)
    for i in range(16):
        (recv_buf + i)[] = UInt8(0)

    # Wire send completion.
    var send_tracker = ResultTracker()
    var send_ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=send_tracker))
    )
    var send_cmp = Completion(
        invoke=ResultTracker.on_complete, context=send_ctx
    )
    var send_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=send_cmp))
    )

    # Wire recv completion.
    var recv_tracker = ResultTracker()
    var recv_ctx = UnsafePointer[NoneType, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=recv_tracker))
    )
    var recv_cmp = Completion(
        invoke=ResultTracker.on_complete, context=recv_ctx
    )
    var recv_cmp_ptr = UnsafePointer[Completion, MutAnyOrigin](
        unsafe_from_address=Int(UnsafePointer(to=recv_cmp))
    )

    # Cast buffer pointers to MutAnyOrigin for the driver API.
    var send_buf_ptr = UnsafePointer[UInt8, MutAnyOrigin](
        unsafe_from_address=Int(send_buf)
    )
    var recv_buf_ptr = UnsafePointer[UInt8, MutAnyOrigin](
        unsafe_from_address=Int(recv_buf)
    )

    # Submit send on fd_a, recv on fd_b.
    driver.submit_send(fd_a, send_buf_ptr, UInt32(5), send_cmp_ptr)
    driver.submit_recv(fd_b, recv_buf_ptr, UInt32(16), recv_cmp_ptr)

    # Tick until both completions fire.
    var ticks = 0
    while not send_tracker.fired or not recv_tracker.fired:
        driver.tick(wait=True)
        ticks += 1
        if ticks > 100:
            raise "timed out waiting for recv/send completion"

    # Assert send result == 5 (bytes sent).
    assert_true(
        Int(send_tracker.result) == 5,
        "send should return 5 bytes sent",
    )

    # Assert recv result == 5 (bytes received).
    assert_true(
        Int(recv_tracker.result) == 5,
        "recv should return 5 bytes received",
    )

    # Assert first byte of recv buffer is 'h' (104).
    assert_true(
        Int(recv_buf[]) == 104,
        "first recv byte should be 'h' (104)",
    )

    # Close both socket FDs.
    _ = external_call["close", Int32](fd_a)
    _ = external_call["close", Int32](fd_b)

    # Free buffers.
    send_buf.free()
    recv_buf.free()

    # Keep completions alive past callback.
    _ = send_cmp
    _ = recv_cmp

    print("PASS: test_driver_recv_send")
