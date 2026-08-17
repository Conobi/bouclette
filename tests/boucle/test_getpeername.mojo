"""Tests for the _getpeername syscall wrapper."""

from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import assert_true, assert_equal

from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4, SocketAddrStorV4
from boucle.net.options import Backlog
from boucle.net.socket import _getpeername


def _getsockname_port_v4(ref s: Socket) raises -> UInt16:
    """Extract the OS-assigned port from a bound IPv4 socket."""
    var stor = SocketAddrStorV4()
    var stor_p = UnsafePointer(to=stor)
    var slen = UInt32(16)
    var len_p = UnsafePointer(to=slen)
    var res = external_call["getsockname", Int32](
        s.raw(), stor_p, len_p,
    )
    if res < 0:
        raise String("getsockname failed: ", Int(res))
    var be = stor.addr.sin_port
    return (UInt16(be) >> 8) | ((UInt16(be) & UInt16(0xFF)) << 8)


def _accept_one(ref server: Socket) raises -> Int32:
    """Accept a single connection, retrying up to 1000 times."""
    var stor = SocketAddrStorV4()
    var stor_p = UnsafePointer(to=stor)
    var slen = UInt32(16)
    var len_p = UnsafePointer(to=slen)
    for _ in range(1000):
        var res = external_call["accept4", Int32](
            server.raw(), stor_p, len_p, Int32(0),
        )
        if res >= 0:
            return res
    raise String("accept timed out")


def test_getpeername() raises:
    # --- Test 1: IPv4 getpeername on an accepted connection ---
    var server = Socket.tcp_v4()
    var bind_addr = SocketAddrV4(127, 0, 0, 1, port=0)
    server.bind(bind_addr)
    server.listen(Backlog.DEFAULT)
    var port = _getsockname_port_v4(server)
    assert_true(port != 0)

    var dest = SocketAddrV4(127, 0, 0, 1, port=port)
    var client = Socket.tcp_connect(dest)
    # Save fd before _accept_one to avoid early-destruction of `client`
    # racing with fd reuse by the kernel.
    var client_fd = client.raw()

    var peer_fd = _accept_one(server)
    assert_true(peer_fd > -1)

    # getpeername on the accepted fd returns the client's loopback address.
    var peer_ip = _getpeername(peer_fd)
    assert_equal(peer_ip, "127.0.0.1")

    # getpeername on the client fd returns the server's loopback address.
    var server_ip = _getpeername(client_fd)
    assert_equal(server_ip, "127.0.0.1")

    _ = external_call["close", Int32](peer_fd)

    # --- Test 2: getpeername on an unconnected socket raises ---
    var unconnected = Socket.tcp_v4()
    var failed = False
    try:
        _ = _getpeername(unconnected.raw())
    except:
        failed = True
    assert_true(failed, "expected getpeername to fail on unconnected socket")


def main() raises:
    test_getpeername()
    print("PASS: test_getpeername.mojo")
