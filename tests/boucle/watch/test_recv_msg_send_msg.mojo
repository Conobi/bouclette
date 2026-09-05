"""`recv_msg` / `send_msg` one-shot over UDP loopback, IPv4 and IPv6, both backends.

The receiver posts a recv_msg with a 64-byte window; the sender posts a
send_msg addressed at the receiver. After run(): both counts equal the
payload length, the receiver decodes the sender's address and port, and
the payload buffer that comes back through take_message() is the very
list that was submitted.
"""

from std.testing import assert_equal, assert_true

from boucle.net import Message, Socket, SocketAddrV4, SocketAddrV6
from boucle.net.options import AddrFamily
from boucle.watch import Backend, RecvMsgFuture, SendMsgFuture, WatchLoop


def _payload(text: String) -> List[UInt8]:
    """Copy a string's bytes into a fresh list.

    Args:
        text: The text to send.

    Returns:
        The bytes as a list.
    """
    var out = List[UInt8]()
    for c in text.as_bytes():
        out.append(c)
    return out^


def _roundtrip_v4(backend: Backend) raises:
    """One datagram from a v4 sender to a v4 receiver on the given backend.

    Args:
        backend: The loop backend to force.
    """
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var rx_port = receiver.local_addr_v4().port
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var tx_port = sender.local_addr_v4().port

    var loop = WatchLoop(capacity=8, backend=backend)

    var window = List[UInt8](length=64, fill=0)
    var window_storage = Int(window.unsafe_ptr())
    var recv_f = loop.recv_msg(receiver, Message(window^))

    var out = Message(_payload("ping"))
    out.set_peer(SocketAddrV4(127, 0, 0, 1, port=rx_port))
    var send_f = loop.send_msg(sender, out^)

    assert_equal(loop.in_flight_count(), 2)
    loop.run()
    assert_equal(loop.in_flight_count(), 0)
    assert_true(send_f.done())
    assert_true(recv_f.done())

    var sent = send_f^.result()
    assert_equal(sent.count, 4)
    assert_true(sent.peer_family() == AddrFamily.INET, "the destination stays set")

    var got = recv_f^.result()
    assert_equal(got.count, 4)
    assert_true(not got.truncated())
    assert_true(not got.control_truncated())
    assert_equal(String(from_utf8=got.transferred()), "ping")
    assert_true(got.peer_family() == AddrFamily.INET)
    var peer = got.peer_v4()
    assert_equal(Int(peer.ip.octets[0]), 127)
    assert_equal(Int(peer.ip.octets[3]), 1)
    assert_equal(peer.port, tx_port, "peer port is the sender's")
    var back = got^.take_message()
    assert_equal(len(back.payload()), 64, "window length unchanged")
    assert_equal(Int(back.payload().unsafe_ptr()), window_storage, "same list")

    receiver.close()
    sender.close()


def _roundtrip_v6(backend: Backend) raises:
    """One datagram from a v6 sender to a v6 receiver on the given backend.

    Args:
        backend: The loop backend to force.
    """
    var receiver = Socket.udp_v6()
    receiver.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=0))
    var rx_port = receiver.local_addr_v6().port
    var sender = Socket.udp_v6()
    sender.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=0))
    var tx_port = sender.local_addr_v6().port

    var loop = WatchLoop(capacity=8, backend=backend)
    var window = List[UInt8](length=64, fill=0)
    var window_storage = Int(window.unsafe_ptr())
    var recv_f = loop.recv_msg(receiver, Message(window^))
    var out = Message(_payload("hello6"))
    out.set_peer(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=rx_port))
    var send_f = loop.send_msg(sender, out^)
    loop.run()

    assert_equal(send_f^.result().count, 6)
    var got = recv_f^.result()
    assert_equal(got.count, 6)
    assert_equal(String(from_utf8=got.transferred()), "hello6")
    assert_true(got.peer_family() == AddrFamily.INET6)
    var peer = got.peer_v6()
    for i in range(7):
        assert_equal(Int(peer.segments()[i]), 0)
    assert_equal(Int(peer.segments()[7]), 1)
    assert_equal(peer.port, tx_port)
    var wrong = False
    try:
        _ = got.peer_v4()
    except e:
        wrong = True
    assert_true(wrong, "peer_v4 on a v6 peer raises")
    var back = got^.take_message()
    assert_equal(len(back.payload()), 64, "window length unchanged")
    assert_equal(Int(back.payload().unsafe_ptr()), window_storage, "same list")

    receiver.close()
    sender.close()


def _truncation_is_reported(backend: Backend) raises:
    """A datagram larger than the window completes with MSG_TRUNC.

    Args:
        backend: The loop backend to force.
    """
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    var rx_port = receiver.local_addr_v4().port
    var sender = Socket.udp_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var recv_f = loop.recv_msg(receiver, Message(List[UInt8](length=4, fill=0)))
    var out = Message(List[UInt8](length=10, fill=0x5A))
    out.set_peer(SocketAddrV4(127, 0, 0, 1, port=rx_port))
    var send_f = loop.send_msg(sender, out^)
    loop.run()

    assert_equal(send_f^.result().count, 10)
    var got = recv_f^.result()
    assert_equal(got.count, 4, "the window is filled")
    assert_true(got.truncated(), "MSG_TRUNC is set")

    receiver.close()
    sender.close()


def main() raises:
    _roundtrip_v4(Backend.AUTO)
    _roundtrip_v4(Backend.EPOLL)
    print("ok: v4 round-trip on both backends")
    _roundtrip_v6(Backend.AUTO)
    _roundtrip_v6(Backend.EPOLL)
    print("ok: v6 round-trip on both backends")
    _truncation_is_reported(Backend.AUTO)
    _truncation_is_reported(Backend.EPOLL)
    print("ok: truncation reported on both backends")
    print("PASS: test_recv_msg_send_msg.mojo")
