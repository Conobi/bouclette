"""`send_to` / `recv_from`: the buffer-plus-address wrappers over send_msg / recv_msg.

Both families, both backends. The result types are the message ones,
so the peer and the buffer come back the same way.
"""

from std.testing import assert_equal, assert_true

from boucle.net import Socket, SocketAddrV4, SocketAddrV6
from boucle.net.options import AddrFamily
from boucle.watch import Backend, WatchLoop


def _v4(backend: Backend) raises:
    """`send_to` a v4 receiver; recv_from decodes the v4 sender.

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
    var window = List[UInt8](length=32, fill=0)
    var storage = Int(window.unsafe_ptr())
    var recv_f = loop.recv_from(receiver, window^)
    var send_f = loop.send_to(
        sender, List[UInt8](length=3, fill=UInt8(ord("a"))),
        SocketAddrV4(127, 0, 0, 1, port=rx_port),
    )
    loop.run()

    var sent = send_f^.result()
    assert_equal(sent.count, 3)
    var got = recv_f^.result()
    assert_equal(got.count, 3)
    assert_equal(String(from_utf8=got.transferred()), "aaa")
    assert_true(got.peer_family() == AddrFamily.INET)
    assert_equal(got.peer_v4().port, tx_port)
    var back = got^.take_message().take_payload()
    assert_equal(len(back), 32)
    assert_equal(Int(back.unsafe_ptr()), storage, "the submitted list comes back")

    receiver.close()
    sender.close()


def _v6(backend: Backend) raises:
    """`send_to` a v6 receiver; recv_from decodes the v6 sender.

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
    var recv_f = loop.recv_from(receiver, List[UInt8](length=32, fill=0))
    var send_f = loop.send_to(
        sender, List[UInt8](length=5, fill=UInt8(ord("z"))),
        SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=rx_port),
    )
    loop.run()

    assert_equal(send_f^.result().count, 5)
    var got = recv_f^.result()
    assert_equal(got.count, 5)
    assert_true(got.peer_family() == AddrFamily.INET6)
    var peer = got.peer_v6()
    assert_equal(Int(peer.segments()[7]), 1)
    assert_equal(peer.port, tx_port)

    receiver.close()
    sender.close()


def main() raises:
    _v4(Backend.AUTO)
    _v4(Backend.EPOLL)
    print("ok: v4 send_to/recv_from on both backends")
    _v6(Backend.AUTO)
    _v6(Backend.EPOLL)
    print("ok: v6 send_to/recv_from on both backends")
    print("PASS: test_send_to_recv_from.mojo")
