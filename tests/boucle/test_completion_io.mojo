from boucle.completion import CompletionLoop, CompletionHandler
from boucle.handle import RawHandle
from std.ffi import external_call
from std.testing import assert_equal, assert_true


struct IOTracker(CompletionHandler):
    var results: InlineArray[Int32, 4]
    var count: Int

    def __init__(out self):
        self.results = InlineArray[Int32, 4](fill=0)
        self.count = 0

    def __init__(out self, *, deinit take: Self):
        self.results = take.results
        self.count = take.count

    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        if self.count < 4:
            self.results[self.count] = result
        self.count += 1


def test_completion_io() raises:
    # Create pipe
    var pipefd = InlineArray[Int32, 2](fill=0)
    var res = external_call["pipe", Int32](
        UnsafePointer(to=pipefd).bitcast[Int32]()
    )
    assert_equal(Int(res), 0)
    var read_fd: RawHandle = pipefd[0]
    var write_fd: RawHandle = pipefd[1]

    var loop = CompletionLoop(IOTracker(), sq_entries=8)

    # Write through CompletionLoop
    var msg = String("hello")
    var msg_ptr = UnsafePointer[Int8, StaticConstantOrigin](
        unsafe_from_address=Int(msg.unsafe_ptr())
    )
    loop.submit_write(write_fd, msg_ptr, 5, token=1)
    loop.run()
    assert_equal(loop._handler.count, 1)
    assert_equal(loop._handler.results[0], Int32(5))  # 5 bytes written

    # Read through CompletionLoop
    var buf = List[UInt8](length=16, fill=0)
    var buf_ptr = UnsafePointer[Int8, StaticConstantOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    loop.submit_read(read_fd, buf_ptr, 16, token=2)
    loop.run()
    assert_equal(loop._handler.count, 2)
    assert_equal(loop._handler.results[1], Int32(5))  # 5 bytes read

    # Cleanup
    _ = external_call["close", Int32](read_fd)
    _ = external_call["close", Int32](write_fd)


def main() raises:
    test_completion_io()
    print("PASS: test_completion_io.mojo")
