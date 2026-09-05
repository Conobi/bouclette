"""Tests for Socket.send_to() and Socket.recv_from_v6() over UDP/IPv6.

Creates two UDP IPv6 sockets bound to [::1] on ephemeral ports. The
sender delivers a datagram with send_to; the receiver reads it with
recv_from_v6 and verifies the sender's source address and port.

A second datagram is then read with recv_from_v4 on the same IPv6
receiver: the kernel reports an AF_INET6 source, so the call must raise
IOError(EAFNOSUPPORT) rather than decode a truncated address.
"""

from std.testing import assert_true, assert_equal

from boucle.error import IOError
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV6
from boucle.socle.linux.raw import EAFNOSUPPORT


def main() raises:
    # --- Receiver bound to [::1]:0 ---
    var receiver = Socket.udp_v6()
    receiver.set_blocking(True)
    receiver.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=0))
    var receiver_port = receiver.local_addr_v6().port
    assert_true(Int(receiver_port) > 0, "receiver ephemeral port should be > 0")

    # --- Sender bound to [::1]:0 so its source port is known ---
    var sender = Socket.udp_v6()
    sender.set_blocking(True)
    sender.bind(SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=0))
    var sender_port = sender.local_addr_v6().port
    assert_true(Int(sender_port) > 0, "sender ephemeral port should be > 0")

    # --- send_to an IPv6 destination ---
    var msg = String("hello")
    var dest = SocketAddrV6(0, 0, 0, 0, 0, 0, 0, 1, port=receiver_port)
    var sent = sender.send_to(msg.as_bytes(), dest)
    assert_equal(sent, 5, "should send 5 bytes")

    # --- recv_from_v6 returns the payload and the IPv6 source ---
    var buf = InlineArray[UInt8, 64](fill=0)
    var result = receiver.recv_from_v6(Span(buf))
    var received = result[0]
    var src = result[1]
    assert_equal(received, 5, "should receive 5 bytes")
    assert_equal(buf[0], UInt8(ord("h")), "byte 0 should be 'h'")
    assert_equal(buf[4], UInt8(ord("o")), "byte 4 should be 'o'")
    for i in range(7):
        assert_equal(
            Int(src.ip.segments[i]), 0, "src segment " + String(i) + " should be 0"
        )
    assert_equal(Int(src.ip.segments[7]), 1, "src segment 7 should be 1")
    assert_equal(src.port, sender_port, "src port should be the sender's port")

    # --- recv_from_v4 on an IPv6 socket must refuse the AF_INET6 source ---
    _ = sender.send_to(msg.as_bytes(), dest)
    var raised = False
    try:
        _ = receiver.recv_from_v4(Span(buf))
    except e:
        raised = True
        assert_equal(e.errno_value(), EAFNOSUPPORT)
    assert_true(raised, "recv_from_v4 on an IPv6 socket should raise")

    sender.close()
    receiver.close()
    print("PASS: Socket.send_to() and Socket.recv_from_v6() over IPv6")
