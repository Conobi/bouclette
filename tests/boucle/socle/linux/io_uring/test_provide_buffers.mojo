from boucle import CompletionLoop, CompletionHandler
from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc as _heap_alloc
from std.testing import assert_equal, assert_true


struct Tracker(CompletionHandler):
    var called: Bool
    var token: UInt64
    var result: Int32
    var flags: UInt32

    def __init__(out self):
        self.called = False
        self.token = 0
        self.result = 0
        self.flags = 0

    def __init__(out self, *, deinit take: Self):
        self.called = take.called
        self.token = take.token
        self.result = take.result
        self.flags = take.flags

    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        self.called = True
        self.token = token
        self.result = result
        self.flags = flags
        print(
            "on_complete: token=",
            token,
            " result=",
            result,
            " flags=",
            flags,
        )


def test_provide_buffers() raises:
    # 4 buffers x 256 bytes = 1024 bytes total
    comptime BUF_SIZE = 256
    comptime BUF_COUNT = 4
    var pool = _heap_alloc[UInt8](BUF_SIZE * BUF_COUNT)
    for i in range(BUF_SIZE * BUF_COUNT):
        pool[i] = 0

    print("pool address=", Int(pool))

    var loop = CompletionLoop(Tracker())
    loop.provide_buffers(
        pool,
        buf_size=BUF_SIZE,
        count=BUF_COUNT,
        group_id=1,
        base_buf_id=0,
        token=42,
    )
    loop.poll(wait_nr=1)

    assert_true(loop._handler.called, "on_complete was not called")
    assert_equal(loop._handler.token, UInt64(42))
    assert_true(
        loop._handler.result >= 0,
        "provide_buffers failed with result=" + String(loop._handler.result),
    )

    pool.free()
    print("test_provide_buffers PASSED")


def main() raises:
    test_provide_buffers()
