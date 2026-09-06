"""Control records written by the kernel on a receive never go out on a send.

A receiver with `set_recv_tos` gets an `IP_TOS` record carrying the
peer's whole TOS byte (DSCP and ECN). When the application answers by
reusing the received message, `sendmsg` must not be offered that record:
otherwise the peer chooses the DSCP of every reply. The sender here
marks its datagram 0xE0 (DSCP 56, ECN 0) and reads the TOS byte of the
reply back with its own `set_recv_tos`.

Both backends run the same scenario.
"""

from std.testing import assert_equal, assert_true

from boucle.net import ControlMessages, Message, Socket, SocketAddrV4
from boucle.socle.platform import IP_TOS, SOL_IP
from boucle.watch import Backend, WatchLoop


def _tos_byte(walker: ControlMessages) -> Optional[UInt8]:
    """Return the data byte of the first `IP_TOS` record.

    Args:
        walker: The control records of a received datagram.

    Returns:
        The whole TOS byte, or None when no `IP_TOS` record is present.
    """
    for cm in walker:
        if (
            cm.level == Int32(SOL_IP)
            and cm.type == Int32(IP_TOS)
            and len(cm.data()) >= 1
        ):
            return cm.data()[0]
    return None


def _reply_tos(backend: Backend) raises:
    """A reply built from a received message carries the socket's own TOS.

    Args:
        backend: The loop backend to force.
    """
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    receiver.set_recv_tos()
    var receiver_addr = receiver.local_addr_v4()
    var sender = Socket.udp_v4()
    sender.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    sender.set_recv_tos()
    sender.set_tos(0xE0)

    var loop = WatchLoop(capacity=8, backend=backend)
    var recv_f = loop.recv_msg(
        receiver, Message(List[UInt8](length=16, fill=0), control_capacity=64)
    )
    var send_f = loop.send_to(
        sender, List[UInt8](length=4, fill=0x2A), receiver_addr
    )
    loop.run()
    assert_equal(send_f^.result().count, 4)
    var got = recv_f^.result()
    assert_equal(got.count, 4)
    var seen = _tos_byte(got.control())
    assert_true(Bool(seen), "the receiver sees an IP_TOS record")
    assert_equal(Int(seen.value()), 0xE0, "... carrying the sender's TOS")

    # Reuse the received message as the reply: its peer is the sender.
    var reply = got^.take_message()
    var reply_recv = loop.recv_msg(
        sender, Message(List[UInt8](length=16, fill=0), control_capacity=64)
    )
    var reply_send = loop.send_msg(receiver, reply^)
    loop.run()
    var sent = reply_send^.result()
    assert_equal(sent.count, 16)
    var echoed = reply_recv^.result()
    assert_equal(echoed.count, 16)
    var reply_tos = _tos_byte(echoed.control())
    assert_true(Bool(reply_tos), "the sender sees an IP_TOS record")
    assert_equal(
        Int(reply_tos.value()),
        0,
        "the reply carries the receiver's default TOS, not the peer's 0xE0",
    )

    # An explicit ECN mark on the reused message is the whole TOS byte.
    var marked = sent^.take_message()
    marked.set_ecn(1)
    var marked_recv = loop.recv_msg(
        sender, Message(List[UInt8](length=16, fill=0), control_capacity=64)
    )
    var marked_send = loop.send_msg(receiver, marked^)
    loop.run()
    assert_equal(marked_send^.result().count, 16)
    var marked_got = marked_recv^.result()
    var marked_tos = _tos_byte(marked_got.control())
    assert_true(Bool(marked_tos), "the sender sees an IP_TOS record")
    assert_equal(Int(marked_tos.value()), 1, "ECN 1 with DSCP 0")
    receiver.close()
    sender.close()


def main() raises:
    _reply_tos(Backend.AUTO)
    print("ok: reply TOS on AUTO")
    _reply_tos(Backend.EPOLL)
    print("ok: reply TOS on EPOLL")
    print("PASS: test_control_replay.mojo")
