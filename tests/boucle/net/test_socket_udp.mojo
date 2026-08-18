"""Tests for Socket.send_to() and Socket.recv_from() with UDP.

Creates two UDP IPv4 sockets: a receiver bound to 127.0.0.1 on an
ephemeral port, and a sender that uses send_to to deliver a datagram.
The receiver calls recv_from to read the datagram and verify the
sender's source address.

Uses external_call for bind to work around the TRP pointer corruption
issue in Mojo 1.0.0.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.testing import assert_true, assert_equal

from boucle.handle import OwnedHandle
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.ip import IpAddrV4
from boucle.socle.linux.raw import (
    sockaddr_in,
    socklen_t,
    AF_INET,
)
from boucle.socle.linux.raw.utils import _to_be
from boucle.socle.linux.errno import get_errno


def _bind_v4(ref sock: Socket, ref addr: SocketAddrV4) raises:
    """Bind a socket to an IPv4 address using external_call directly.

    Works around the TRP pointer corruption issue in Mojo 1.0.0
    by using InlineArray as intermediate buffer.
    """
    var stor = addr.addr_stor()
    var buf = InlineArray[UInt8, 16](fill=0)
    var buf_p = Pointer(to=buf)
    # Copy the sockaddr_in into the raw buffer.
    var src_p = Pointer(to=stor.addr)
    var dst = buf_p.unsafe_bitcast[sockaddr_in]()
    dst[] = src_p[]
    var res = external_call["bind", Int32](
        sock.raw(),
        buf_p,
        socklen_t(16),
    )
    if res < 0:
        var errno = get_errno()
        raise String("bind failed: errno=", Int(errno))


def main() raises:
    # --- Create UDP receiver socket, bind to 127.0.0.1:0 ---
    var receiver = Socket.udp_v4()
    receiver.set_blocking(True)
    var bind_addr = SocketAddrV4(127, 0, 0, 1, port=0)
    _bind_v4(receiver, bind_addr)

    # --- Retrieve the ephemeral port assigned by the kernel ---
    var local = receiver.local_addr_v4()
    var local_port = _to_be[DType.uint16, 1](local.addr.sin_port)
    assert_true(Int(local_port) > 0, "ephemeral port should be > 0")

    # --- Create UDP sender socket ---
    var sender = Socket.udp_v4()
    sender.set_blocking(True)

    # --- send_to "hello" to receiver ---
    var msg = String("hello")
    var dest = SocketAddrV4(127, 0, 0, 1, port=local_port)
    var sent = sender.send_to(msg.as_bytes(), dest)
    assert_equal(sent, 5, "should send 5 bytes")

    # --- recv_from on receiver ---
    var buf = InlineArray[UInt8, 64](fill=0)
    var result = receiver.recv_from(Span(buf))
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
    var src_ip_ptr = Pointer(to=src_addr.addr.sin_addr_s_addr).unsafe_bitcast[UInt8]()
    assert_equal(src_ip_ptr[unsafe_offset=0], UInt8(127), "src IP byte 0")
    assert_equal(src_ip_ptr[unsafe_offset=1], UInt8(0), "src IP byte 1")
    assert_equal(src_ip_ptr[unsafe_offset=2], UInt8(0), "src IP byte 2")
    assert_equal(src_ip_ptr[unsafe_offset=3], UInt8(1), "src IP byte 3")

    # --- Clean up ---
    sender.close()
    receiver.close()
    print("PASS: Socket.send_to() and Socket.recv_from()")
