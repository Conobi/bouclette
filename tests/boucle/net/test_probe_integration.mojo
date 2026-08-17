"""Integration test: ConnectProbe with real io_uring."""

from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import assert_equal, assert_true

from boucle.net.probe import PortStatus
from boucle.net.connect_probe import ConnectProbe
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog
from boucle.proactor.loop import EventLoop
from boucle.drivers.io_uring import IoUringDriver
from boucle.socle.linux.raw import sockaddr_in


def test_connect_open_port() raises:
    """Connect to a listening port -> OPEN."""
    var server = Socket.tcp_v4()
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)

    # Discover ephemeral port via getsockname.
    var bound = sockaddr_in()
    var bound_len = Int32(16)
    _ = external_call["getsockname", Int32](
        server.raw(),
        UnsafePointer(to=bound).bitcast[Int8](),
        UnsafePointer(to=bound_len).bitcast[Int8](),
    )
    var port = ((UInt16(bound.sin_port) << 8) | (UInt16(bound.sin_port) >> 8)) & UInt16(0xFFFF)

    var driver = IoUringDriver(sq_entries=64)
    var loop = EventLoop[IoUringDriver](driver^)

    # Stack-allocated probe: address is stable (no moves after wire_context).
    var probe = ConnectProbe(target=SocketAddrV4(127, 0, 0, 1, port=port), timeout_ms=2000)
    probe.wire_context()
    probe.submit(loop)

    while not probe.is_done():
        loop.run_once()
        probe.flush_cancel(loop)

    assert_true(probe.result_status() == PortStatus.OPEN)
    assert_equal(probe._total_cqes, 3)

    _ = server^


def test_connect_closed_port() raises:
    """Connect to port with no listener -> CLOSED."""
    var driver = IoUringDriver(sq_entries=64)
    var loop = EventLoop[IoUringDriver](driver^)

    var probe = ConnectProbe(target=SocketAddrV4(127, 0, 0, 1, port=1), timeout_ms=2000)
    probe.wire_context()
    probe.submit(loop)

    while not probe.is_done():
        loop.run_once()
        probe.flush_cancel(loop)

    assert_true(probe.result_status() == PortStatus.CLOSED)
    assert_equal(probe._total_cqes, 3)


def main() raises:
    test_connect_open_port()
    test_connect_closed_port()
    print("PASS: test_probe_integration")
