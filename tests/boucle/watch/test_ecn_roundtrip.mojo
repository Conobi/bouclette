"""ECN codepoints travel per datagram through control messages, four ways.

1. v4 sender to v4 receiver: IP_TOS out, IP_TOS in.
2. v6 sender to v6 receiver: IPV6_TCLASS out, IPV6_TCLASS in.
3. v4 sender to a dual-stack receiver: IP_TOS out; the receiver's
   `set_recv_tos` also enabled IP_RECVTOS on the AF_INET6 socket, so an
   IP_TOS record arrives with a mapped peer.
4. dual-stack sender with `set_ecn` to a v4-mapped peer: the peer is
   IPv6-shaped but the record must be IP_TOS, because the kernel hands a
   mapped destination to the IPv4 sender before it parses IPv6 control
   messages; a v4 receiver reads the mark.

Every case runs on Backend.AUTO and Backend.EPOLL.
"""

from std.testing import assert_equal, assert_true

from boucle.net import Message, Socket, SocketAddrV4, SocketAddrV6
from boucle.net.options import AddrFamily
from boucle.watch import Backend, WatchLoop


def _exchange(
    backend: Backend, ref receiver: Socket, ref sender: Socket, var out: Message
) raises -> Optional[UInt8]:
    """Send `out` and receive it with a 64-byte control area; return the ECN mark.

    Args:
        backend: The loop backend to force.
        receiver: The bound socket that receives.
        sender: The socket that sends; `out` must already name the peer.
        out: The message to send, with its ECN record appended.

    Returns:
        The codepoint the receiver's control walker yields, if any.
    """
    var loop = WatchLoop(capacity=8, backend=backend)
    var recv_f = loop.recv_msg(
        receiver, Message(List[UInt8](length=64, fill=0), control_capacity=64)
    )
    var send_f = loop.send_msg(sender, out^)
    loop.run()
    assert_equal(send_f^.result().count, 3)
    var got = recv_f^.result()
    assert_equal(got.count, 3)
    assert_true(not got.control_truncated(), "64 bytes hold the record")
    return got.control().ecn()


def _v4_to_v4(backend: Backend) raises:
    """Case 1.

    Args:
        backend: The loop backend to force.
    """
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.set_recv_tos()
    var port = receiver.local_addr_v4().port
    var sender = Socket.udp_v4()
    var out = Message(List[UInt8](length=3, fill=1), control_capacity=24)
    out.set_peer(SocketAddrV4(127, 0, 0, 1, port=port))
    out.set_ecn(1)
    var mark = _exchange(backend, receiver, sender, out^)
    assert_true(Bool(mark), "an IP_TOS record arrived")
    assert_equal(Int(mark.value()), 1)
    receiver.close()
    sender.close()


def _v6_to_v6(backend: Backend) raises:
    """Case 2.

    Args:
        backend: The loop backend to force.
    """
    var receiver = Socket.udp_v6()
    receiver.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=0))
    receiver.set_recv_tos()
    var port = receiver.local_addr_v6().port
    var sender = Socket.udp_v6()
    var out = Message(List[UInt8](length=3, fill=1), control_capacity=24)
    out.set_peer(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=port))
    out.set_ecn(2)
    var mark = _exchange(backend, receiver, sender, out^)
    assert_true(Bool(mark), "an IPV6_TCLASS record arrived")
    assert_equal(Int(mark.value()), 2)
    receiver.close()
    sender.close()


def _v4_to_dual_stack(backend: Backend) raises:
    """Case 3.

    Args:
        backend: The loop backend to force.
    """
    var receiver = Socket.udp_v6()
    receiver.set_v6only(False)
    receiver.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 0, port=0))
    receiver.set_recv_tos()
    var port = receiver.local_addr_v6().port
    var sender = Socket.udp_v4()
    var out = Message(List[UInt8](length=3, fill=1), control_capacity=24)
    out.set_peer(SocketAddrV4(127, 0, 0, 1, port=port))
    out.set_ecn(3)

    var loop = WatchLoop(capacity=8, backend=backend)
    var recv_f = loop.recv_msg(
        receiver, Message(List[UInt8](length=64, fill=0), control_capacity=64)
    )
    var send_f = loop.send_msg(sender, out^)
    loop.run()
    assert_equal(send_f^.result().count, 3)
    var got = recv_f^.result()
    assert_true(got.peer_family() == AddrFamily.INET6, "dual-stack reports a v6 peer")
    assert_true(got.peer_v6().is_ipv4_mapped(), "... which is the mapped v4 sender")
    var mark = got.control().ecn()
    assert_true(Bool(mark), "IP_RECVTOS on the AF_INET6 socket delivers IP_TOS")
    assert_equal(Int(mark.value()), 3)
    receiver.close()
    sender.close()


def _dual_stack_to_mapped_v4(backend: Backend) raises:
    """Case 4.

    Args:
        backend: The loop backend to force.
    """
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.set_recv_tos()
    var port = receiver.local_addr_v4().port
    var sender = Socket.udp_v6()
    sender.set_v6only(False)
    var out = Message(List[UInt8](length=3, fill=1), control_capacity=24)
    out.set_peer(SocketAddrV6(0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001, port=port))
    out.set_ecn(1)  # derives AF_INET from the mapped peer: IP_TOS
    var mark = _exchange(backend, receiver, sender, out^)
    assert_true(Bool(mark), "the IP_TOS record reached the v4 receiver")
    assert_equal(Int(mark.value()), 1)
    receiver.close()
    sender.close()


def main() raises:
    _v4_to_v4(Backend.AUTO)
    _v4_to_v4(Backend.EPOLL)
    print("ok: v4 to v4")
    _v6_to_v6(Backend.AUTO)
    _v6_to_v6(Backend.EPOLL)
    print("ok: v6 to v6")
    _v4_to_dual_stack(Backend.AUTO)
    _v4_to_dual_stack(Backend.EPOLL)
    print("ok: v4 to dual-stack")
    _dual_stack_to_mapped_v4(Backend.AUTO)
    _dual_stack_to_mapped_v4(Backend.EPOLL)
    print("ok: dual-stack to mapped v4")
    print("PASS: test_ecn_roundtrip.mojo")
