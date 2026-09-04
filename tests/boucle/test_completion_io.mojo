"""Test send and recv on CompletionLoop via a socketpair.

Replaces the legacy read/write pipe test with the portable
socket send/recv API.
"""

from boucle.proactor.completion_loop import CompletionLoop
from boucle.proactor.completion import Completion
from boucle.handle import RawHandle
from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_equal, assert_true


struct IOResult:
    """Records a single I/O completion result."""

    var result: Int
    var fired: Bool

    def __init__(out self):
        """Construct an unfired result."""
        self.result = 0
        self.fired = False

    @staticmethod
    def on_complete(
        ctx: Pointer[NoneType, MutUntrackedOrigin],
        result: Int,
        flags: UInt32,
    ):
        """Callback that records the I/O result."""
        var self_ptr = Pointer[IOResult, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].result = result
        self_ptr[].fired = True


def test_completion_io() raises:
    # Create a connected AF_UNIX socketpair (supports send/recv).
    var sv = Array[Int32, 2](fill=0)
    var res = external_call["socketpair", Int32](
        Int32(1),  # AF_UNIX
        Int32(1),  # SOCK_STREAM
        Int32(0),
        Pointer(to=sv).unsafe_bitcast[Int32](),
    )
    assert_equal(Int(res), 0)
    var fd_a: RawHandle = sv[0]
    var fd_b: RawHandle = sv[1]

    var loop = CompletionLoop(capacity=8)

    # ── Send "hello" through CompletionLoop ──────────────────────────────

    var send_slot = IOResult()
    var send_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=send_slot))
    )
    var send_cmp = Completion(invoke=IOResult.on_complete, context=send_ctx)
    var send_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=send_cmp))
    )

    var msg = String("hello")
    var msg_ptr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(msg.unsafe_ptr())
    )
    loop.send(fd_a, msg_ptr, UInt32(5), send_cmp_ptr)
    _ = loop.tick(wait=True)

    assert_true(send_slot.fired, "send completion did not fire")
    assert_equal(send_slot.result, 5)  # 5 bytes sent

    # ── Recv through CompletionLoop ──────────────────────────────────────

    var recv_slot = IOResult()
    var recv_ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=recv_slot))
    )
    var recv_cmp = Completion(invoke=IOResult.on_complete, context=recv_ctx)
    var recv_cmp_ptr = Pointer[Completion, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=recv_cmp))
    )

    var buf = List[UInt8](length=16, fill=0)
    var buf_ptr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    loop.recv(fd_b, buf_ptr, UInt32(16), recv_cmp_ptr)
    _ = loop.tick(wait=True)

    assert_true(recv_slot.fired, "recv completion did not fire")
    assert_equal(recv_slot.result, 5)  # 5 bytes received

    # Cleanup
    _ = external_call["close", Int32](fd_a)
    _ = external_call["close", Int32](fd_b)
    _ = send_cmp
    _ = recv_cmp


def main() raises:
    test_completion_io()
    print("PASS: test_completion_io.mojo")
