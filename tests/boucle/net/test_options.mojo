from boucle.net.options import (
    SocketType, SocketFlags, AddrFamily, Protocol, Backlog, Shutdown,
    SendFlags, RecvFlags,
)
from std.testing import assert_equal, assert_true


def main() raises:
    assert_equal(SocketType.STREAM.id, Int32(1))
    assert_equal(SocketType.DGRAM.id, Int32(2))

    assert_equal(Int(AddrFamily.INET.id), 2)
    assert_equal(Int(AddrFamily.INET6.id), 10)

    assert_equal(Protocol.TCP.id, UInt32(6))
    assert_equal(Protocol.UDP.id, UInt32(17))

    var p = Protocol()
    assert_equal(p.id, UInt32(0))

    var flags = SocketFlags.NONBLOCK | SocketFlags.CLOEXEC
    assert_true(flags.value != SocketFlags.NONBLOCK.value)
    assert_true(flags.value != SocketFlags.CLOEXEC.value)
    assert_true(flags.value == (SocketFlags.NONBLOCK.value | SocketFlags.CLOEXEC.value))

    var default_flags = SocketFlags()
    assert_equal(default_flags.value, UInt32(0))

    var sflags = SendFlags.NOSIGNAL | SendFlags.MORE
    assert_true(sflags.value != SendFlags().value)

    var rflags = RecvFlags.PEEK | RecvFlags.DONTWAIT
    assert_true(rflags.value != RecvFlags().value)

    assert_true(Backlog.DEFAULT.value > 0)

    assert_equal(Shutdown.RDWR.value, Int32(2))

    print("All options tests passed.")
