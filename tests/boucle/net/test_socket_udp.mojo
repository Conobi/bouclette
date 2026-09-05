"""Tests for Socket.send_to() and Socket.recv_from_v4() with UDP.

Creates two UDP IPv4 sockets: a receiver bound to 127.0.0.1 on an
ephemeral port, and a sender that uses send_to to deliver a datagram.
The receiver calls recv_from_v4 to read the datagram and verify the
sender's source address. A second datagram read with recv_from_v6 must
raise IOError(EAFNOSUPPORT): the source is AF_INET, not AF_INET6.
"""

from std.testing import assert_true, assert_equal

from boucle.error import IOError
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.socle.linux.raw import EAFNOSUPPORT


def main() raises:
    # --- Create UDP receiver socket, bind to 127.0.0.1:0 ---
    var receiver = Socket.udp_v4()
    receiver.set_blocking(True)
    receiver.bind(SocketAddrV4(127, 0, 0, 1, port=0))

    # --- Retrieve the ephemeral port assigned by the kernel ---
    var local_port = receiver.local_addr_v4().port
    assert_true(Int(local_port) > 0, "ephemeral port should be > 0")

    # --- Create UDP sender socket ---
    var sender = Socket.udp_v4()
    sender.set_blocking(True)

    # --- send_to "hello" to receiver ---
    var msg = String("hello")
    var dest = SocketAddrV4(127, 0, 0, 1, port=local_port)
    var sent = sender.send_to(msg.as_bytes(), dest)
    assert_equal(sent, 5, "should send 5 bytes")

    # --- recv_from_v4 on receiver ---
    var buf = InlineArray[UInt8, 64](fill=0)
    var result = receiver.recv_from_v4(Span(buf))
    var received = result[0]
    var src_addr = result[1]
    assert_equal(received, 5, "should receive 5 bytes")

    # --- Verify content byte-by-byte ---
    assert_equal(buf[0], UInt8(ord("h")), "byte 0 should be 'h'")
    assert_equal(buf[1], UInt8(ord("e")), "byte 1 should be 'e'")
    assert_equal(buf[2], UInt8(ord("l")), "byte 2 should be 'l'")
    assert_equal(buf[3], UInt8(ord("l")), "byte 3 should be 'l'")
    assert_equal(buf[4], UInt8(ord("o")), "byte 4 should be 'o'")

    # --- Verify source address is 127.0.0.1 ---
    assert_equal(Int(src_addr.ip.octets[0]), 127, "src IP byte 0")
    assert_equal(Int(src_addr.ip.octets[1]), 0, "src IP byte 1")
    assert_equal(Int(src_addr.ip.octets[2]), 0, "src IP byte 2")
    assert_equal(Int(src_addr.ip.octets[3]), 1, "src IP byte 3")

    # --- recv_from_v6 on an IPv4 socket must refuse the AF_INET source ---
    _ = sender.send_to(msg.as_bytes(), dest)
    var raised = False
    try:
        _ = receiver.recv_from_v6(Span(buf))
    except e:
        raised = True
        assert_equal(e.errno_value(), EAFNOSUPPORT)
    assert_true(raised, "recv_from_v6 on an IPv4 socket should raise")

    # --- Clean up ---
    sender.close()
    receiver.close()
    print("PASS: Socket.send_to() and Socket.recv_from_v4()")
