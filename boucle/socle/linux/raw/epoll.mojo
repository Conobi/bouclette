from boucle.socle.linux.raw.ctypes import c_int, c_uint
from boucle.socle.linux.raw.utils import _pick_int, DTypeArray
from std.sys.info import size_of
from std.memory import Pointer

# epoll_ctl operations
comptime EPOLL_CTL_ADD = 1
comptime EPOLL_CTL_DEL = 2
comptime EPOLL_CTL_MOD = 3

# epoll event flags
comptime EPOLLIN = 0x001
comptime EPOLLPRI = 0x002
comptime EPOLLOUT = 0x004
comptime EPOLLERR = 0x008
comptime EPOLLHUP = 0x010
comptime EPOLLRDNORM = 0x040
comptime EPOLLRDBAND = 0x080
comptime EPOLLWRNORM = 0x100
comptime EPOLLWRBAND = 0x200
comptime EPOLLMSG = 0x400
comptime EPOLLRDHUP = 0x2000
comptime EPOLLEXCLUSIVE = 0x10000000
comptime EPOLLWAKEUP = 0x20000000
comptime EPOLLONESHOT = 0x40000000
comptime EPOLLET = 0x80000000

# x86_64: 3 x UInt32 = 12 bytes (packed, no padding before data)
# aarch64: 4 x UInt32 = 16 bytes (slot [1] is padding before data)
comptime _EPOLL_SLOTS = _pick_int[3, 4]()
# data starts at slot [1] on x86_64 (offset 4), slot [2] on aarch64 (offset 8)
comptime _DATA_IDX = _pick_int[1, 2]()


struct epoll_event(ImplicitlyCopyable, Movable):
    """Linux epoll_event struct.

    Packed to 12 bytes on x86_64 (`__attribute__((packed))` for 32-bit
    compat). On all other architectures, natural alignment applies:
    16 bytes with 4-byte padding between `events` and `data`.
    See `#ifdef __x86_64__` / `EPOLL_PACKED` in kernel `eventpoll.h`.
    """

    var _buf: DTypeArray[DType.uint32, _EPOLL_SLOTS]

    @always_inline
    def __init__(out self):
        """Construct a zero-initialized epoll_event."""
        comptime assert size_of[Self]() == _pick_int[12, 16]()
        self._buf = DTypeArray[DType.uint32, _EPOLL_SLOTS]()

    @always_inline
    def __init__(out self, *, events: UInt32, data: UInt64):
        """Construct an epoll_event with the given events mask and data.

        Args:
            events: Epoll event flags (EPOLLIN, EPOLLOUT, etc.).
            data: Opaque user data returned by epoll_wait.
        """
        self._buf = DTypeArray[DType.uint32, _EPOLL_SLOTS]()
        var p = Pointer(to=self._buf).unsafe_bitcast[UInt32]()
        p[unsafe_offset=0] = events
        p[unsafe_offset=Int(_DATA_IDX)] = UInt32(data & 0xFFFF_FFFF)
        p[unsafe_offset=Int(_DATA_IDX) + 1] = UInt32(data >> 32)

    @always_inline
    def events(self) -> UInt32:
        """Return the event flags."""
        return self._buf[UInt(0)]

    @always_inline
    def data(self) -> UInt64:
        """Return the opaque user data."""
        var lo = UInt64(self._buf[UInt(_DATA_IDX)])
        var hi = UInt64(self._buf[UInt(_DATA_IDX + 1)])
        return lo | (hi << 32)
