"""WatchLoop.send()/recv() own the buffer until the operation completes.

The buffer handed to `send`/`recv` moves into the loop-owned per-operation
state, right next to the Completion the driver holds. The caller cannot
read it, write it or free it while the kernel may be using it: the value
is gone until `result()` gives it back. Dropping the future without
calling `result()` is therefore harmless — the buffer stays with the loop
and is released once the completion has arrived.

These tests cover the shapes the old borrowed-buffer API could not make
safe: a future dropped before `run()`, a future dropped inside a call
that returns before `run()`, the buffer coming back from `result()`
intact and reusable, and a zero-length receive.
"""

from std.testing import assert_equal, assert_true

from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.net.socket import Socket
from boucle.watch import WatchLoop, RecvFuture, SendFuture


struct _Pair(Movable):
    """A connected TCP pair on loopback, plus the listener that made it.

    Fields:
        server: The listening socket.
        client: The connecting side.
        peer: The accepted side.
    """

    var server: Socket
    var client: Socket
    var peer: Socket

    def __init__(out self) raises:
        """Bind a listener, connect a client, accept the peer."""
        self.server = Socket.tcp_v4()
        self.server.set_reuse_addr()
        self.server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
        self.server.listen(Backlog.DEFAULT)
        var port = self.server.local_addr_v4().port

        self.client = Socket.tcp_v4()
        var loop = WatchLoop()
        var accept_f = loop.accept(self.server)
        var connect_f = loop.connect(
            self.client, SocketAddrV4(127, 0, 0, 1, port=port)
        )
        loop.run()

        assert_true(connect_f.result().is_connected(), "client should connect")
        self.peer = accept_f.result()

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source pair to move from.
        """
        self.server = move.server^
        self.client = move.client^
        self.peer = move.peer^

    def close(mut self) raises:
        """Close all three sockets."""
        self.peer.close()
        self.client.close()
        self.server.close()


def _bytes(text: String) -> List[UInt8]:
    """Copy a string's bytes into an owned list.

    Args:
        text: The text to copy.

    Returns:
        A list holding the UTF-8 bytes of `text`.
    """
    var out = List[UInt8]()
    for c in text.as_bytes():
        out.append(c)
    return out^


def _drop_recv(var future: RecvFuture):
    """Destroy a RecvFuture without reading its result.

    The future dies when this call returns, which is the whole point:
    the buffer it carried stays with the loop.

    Args:
        future: The future to drop.
    """
    pass


def _drop_send(var future: SendFuture):
    """Destroy a SendFuture without reading its result.

    Args:
        future: The future to drop.
    """
    pass


def test_result_hands_the_buffers_back() raises:
    """The result hands the bytes that travelled, in reusable buffers.

    The receive buffer comes back holding the message; the send buffer
    comes back untouched. Both are ordinary `List[UInt8]` values
    afterwards — appending to them proves they are whole lists, not a
    view into memory the loop still owns.
    """
    var pair = _Pair()
    var msg = String("hello boucle")

    var loop = WatchLoop()
    var send_f = loop.send(pair.client, _bytes(msg))
    var recv_f = loop.recv(pair.peer, List[UInt8](length=32, fill=0))
    loop.run()

    var sent = send_f^.result()
    var received = recv_f^.result()
    assert_equal(
        sent.count, msg.byte_length(), "should have sent the whole message"
    )
    assert_equal(
        received.count, sent.count, "should have received every sent byte"
    )
    assert_equal(
        String(from_utf8=received.transferred()),
        msg,
        "received bytes should equal the sent bytes",
    )
    assert_equal(
        String(from_utf8=sent.transferred()),
        msg,
        "the send buffer should come back untouched",
    )

    var in_buf = received^.take_buffer()
    var out_buf = sent^.take_buffer()
    assert_equal(len(in_buf), 32, "recv leaves the buffer's length alone")
    assert_equal(len(out_buf), msg.byte_length(), "the send buffer is intact")

    in_buf.append(33)
    out_buf.append(33)
    assert_equal(len(in_buf), 33, "the returned buffer stays usable")
    assert_equal(
        len(out_buf), msg.byte_length() + 1, "the returned buffer stays usable"
    )

    pair.close()


def test_future_dropped_before_run() raises:
    """Dropping both futures before run() is harmless.

    Nothing in the caller's scope refers to the buffers any more, so if
    the loop did not own them the kernel would read and write freed
    memory. run() must complete the operations and free the buffers
    itself.
    """
    var pair = _Pair()

    var loop = WatchLoop()
    var send_f = loop.send(pair.client, _bytes(String("hello boucle")))
    var recv_f = loop.recv(pair.peer, List[UInt8](length=32, fill=0))
    _ = send_f^
    _ = recv_f^

    loop.run()
    assert_equal(loop._pending, 0, "run() should drain the orphaned buffers")
    assert_equal(loop.in_flight_count(), 0, "registry should be empty")

    pair.close()


def test_future_dropped_in_a_call_that_returns_before_run() raises:
    """A future that dies inside a call still leaves its buffer with the loop.

    `_drop_recv` and `_drop_send` consume the future, so it is destroyed
    strictly before run() is reached — the case a borrowed buffer could
    not survive.
    """
    var pair = _Pair()

    var loop = WatchLoop()
    _drop_send(loop.send(pair.client, _bytes(String("hello boucle"))))
    _drop_recv(loop.recv(pair.peer, List[UInt8](length=32, fill=0)))

    loop.run()
    assert_equal(loop._pending, 0, "run() should drain both operations")
    assert_equal(loop.in_flight_count(), 0, "registry should be empty")

    pair.close()


def test_recv_into_a_zero_length_list() raises:
    """A recv whose buffer has no room reads nothing and gives it back.

    The list's current length is the readable window, so a zero-length
    list asks the kernel for zero bytes. A byte is sent first because a
    recv with an empty window still waits for the socket to become
    readable — an empty buffer means "read nothing", not "return now".
    """
    var pair = _Pair()
    _ = pair.client.send(String("x").as_bytes())

    var loop = WatchLoop()
    var recv_f = loop.recv(pair.peer, List[UInt8]())
    loop.run()

    var received = recv_f^.result()
    assert_equal(received.count, 0, "a zero-length window reads nothing")
    var buf = received^.take_buffer()
    assert_equal(len(buf), 0, "the empty buffer comes back empty")

    pair.close()


def main() raises:
    test_result_hands_the_buffers_back()
    print("ok: result hands the buffers back")
    test_future_dropped_before_run()
    print("ok: futures dropped before run")
    test_future_dropped_in_a_call_that_returns_before_run()
    print("ok: future dropped inside a call")
    test_recv_into_a_zero_length_list()
    print("ok: recv into a zero-length list")
    print("PASS: test_buffer_lifetime.mojo")
