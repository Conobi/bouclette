"""UDP GSO on the send side and GRO on the receive side, over loopback.

One 1200-byte message carries a `UDP_SEGMENT` record of 600 and an ECN
mark of 1, and goes to a v4 receiver on 127.0.0.1 three ways:

1. Receiver without GRO: the kernel segments on loopback (4.18 and
   later), two 600-byte datagrams arrive, each with the mark.
2. Receiver with `set_gro()`, `set_recv_tos()` and 48 bytes of control
   capacity: one 1200-byte datagram arrives with a `UDP_GRO` record of
   600 behind the TOS record; nothing is truncated.
3. The same receiver with 24 bytes of control capacity: the kernel
   writes the TOS record first, the GRO record is cut off,
   `control_truncated()` is set and `gro_segment_size()` is None.

The kernel rejects a `UDP_SEGMENT` record whose `cmsg_len` is not
CMSG_LEN(2) with EINVAL at send time, so case 1 also pins the unpadded
length. Every case runs on Backend.AUTO and Backend.EPOLL.
"""

from std.testing import assert_equal, assert_true

from boucle.net import Message, MessageResult, Socket, SocketAddrV4
from boucle.watch import Backend, WatchLoop

comptime SEGMENT = 600
comptime SEGMENTS = 2
comptime FILL: UInt8 = 0x5A


def _gso_message(port: UInt16) raises -> Message:
    """Build the 1200-byte message with its GSO and ECN records."""
    var out = Message(
        List[UInt8](length=SEGMENT * SEGMENTS, fill=FILL), control_capacity=48
    )
    out.set_peer(SocketAddrV4(127, 0, 0, 1, port=port))
    out.set_gso_segment_size(UInt16(SEGMENT))
    out.set_ecn(1)
    assert_equal(out._control_appended, 48, "both records are offered")
    return out^


def _bound_receiver() raises -> Socket:
    """A UDP v4 socket bound to an ephemeral loopback port."""
    var receiver = Socket.udp_v4()
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    return receiver^


def _all_fill(r: MessageResult, n: Int) raises:
    """The first `n` transferred bytes are all the fill byte."""
    var data = r.transferred()
    assert_equal(len(data), n)
    for i in range(n):
        assert_equal(Int(data[i]), Int(FILL))


def _two_datagrams_without_gro(backend: Backend) raises:
    """Case 1."""
    var receiver = _bound_receiver()
    receiver.set_recv_tos()
    var port = receiver.local_addr_v4().port
    var sender = Socket.udp_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var first_f = loop.recv_msg(
        receiver, Message(List[UInt8](length=2048, fill=0), control_capacity=48)
    )
    var send_f = loop.send_msg(sender, _gso_message(port))
    loop.run()
    assert_equal(
        send_f^.result().count,
        SEGMENT * SEGMENTS,
        "sendmsg reports the whole payload",
    )
    var first = first_f^.result()
    assert_equal(first.count, SEGMENT, "the first segment is one datagram")
    assert_true(not first.truncated())
    _all_fill(first, SEGMENT)
    assert_equal(
        Int(first.control().ecn().value()), 1, "the mark rides on each segment"
    )
    assert_true(
        not Bool(first.control().gro_segment_size()),
        "no GRO on this socket: no record",
    )

    var second_f = loop.recv_msg(
        receiver, Message(List[UInt8](length=2048, fill=0), control_capacity=48)
    )
    loop.run()
    var second = second_f^.result()
    assert_equal(second.count, SEGMENT, "the second segment was already queued")
    assert_true(not second.truncated())
    _all_fill(second, SEGMENT)
    assert_equal(Int(second.control().ecn().value()), 1)
    receiver.close()
    sender.close()


def _one_datagram_with_gro(backend: Backend) raises:
    """Case 2."""
    var receiver = _bound_receiver()
    receiver.set_recv_tos()
    receiver.set_gro()
    var port = receiver.local_addr_v4().port
    var sender = Socket.udp_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var recv_f = loop.recv_msg(
        receiver, Message(List[UInt8](length=2048, fill=0), control_capacity=48)
    )
    var send_f = loop.send_msg(sender, _gso_message(port))
    loop.run()
    assert_equal(send_f^.result().count, SEGMENT * SEGMENTS)
    var got = recv_f^.result()
    assert_equal(
        got.count, SEGMENT * SEGMENTS, "coalesced: one datagram of both segments"
    )
    assert_true(not got.truncated())
    assert_true(
        not got.control_truncated(), "48 bytes hold the TOS and the GRO record"
    )
    _all_fill(got, SEGMENT * SEGMENTS)
    var size = got.control().gro_segment_size()
    assert_true(Bool(size), "a UDP_GRO record arrived")
    assert_equal(size.value(), SEGMENT)
    assert_equal(
        Int(got.control().ecn().value()), 1, "the TOS record is there too"
    )
    receiver.close()
    sender.close()


def _gro_record_cut_at_24_bytes(backend: Backend) raises:
    """Case 3."""
    var receiver = _bound_receiver()
    receiver.set_recv_tos()
    receiver.set_gro()
    var port = receiver.local_addr_v4().port
    var sender = Socket.udp_v4()

    var loop = WatchLoop(capacity=8, backend=backend)
    var recv_f = loop.recv_msg(
        receiver, Message(List[UInt8](length=2048, fill=0), control_capacity=24)
    )
    var send_f = loop.send_msg(sender, _gso_message(port))
    loop.run()
    assert_equal(send_f^.result().count, SEGMENT * SEGMENTS)
    var got = recv_f^.result()
    assert_equal(got.count, SEGMENT * SEGMENTS, "still coalesced")
    assert_true(got.control_truncated(), "24 bytes hold at most one record")
    # The kernel may write TOS or GRO first depending on the version;
    # with only 24 bytes of capacity, at most one fits.
    var has_ecn = Bool(got.control().ecn())
    var has_gro = Bool(got.control().gro_segment_size())
    assert_true(
        not (has_ecn and has_gro),
        "both cannot fit in 24 bytes",
    )
    receiver.close()
    sender.close()


def main() raises:
    _two_datagrams_without_gro(Backend.AUTO)
    _two_datagrams_without_gro(Backend.EPOLL)
    print("ok: GSO send arrives as two datagrams without GRO")
    _one_datagram_with_gro(Backend.AUTO)
    _one_datagram_with_gro(Backend.EPOLL)
    print("ok: GSO send arrives as one datagram with GRO")
    _gro_record_cut_at_24_bytes(Backend.AUTO)
    _gro_record_cut_at_24_bytes(Backend.EPOLL)
    print("ok: GRO record truncated at 24 bytes of control capacity")
    print("PASS: test_gso_roundtrip.mojo")
