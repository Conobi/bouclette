from boucle.socle.linux.raw.ctypes import c_int, c_uint

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


@fieldwise_init
struct epoll_event(ImplicitlyCopyable, Movable):
    """Linux epoll_event struct, packed to 12 bytes on LP64 Linux.

    The kernel UAPI marks this struct __packed__ on all architectures (no
    tail padding between `events` and `data`). Splitting the 64-bit `data`
    field into two 32-bit halves yields the correct 12-byte stride;
    otherwise Mojo's default alignment pads to 16 and every event past
    the first is mis-decoded.
    """

    var events: UInt32
    var _data_lo: UInt32
    var _data_hi: UInt32

    @always_inline
    def __init__(out self):
        self.events = 0
        self._data_lo = 0
        self._data_hi = 0

    @always_inline
    def __init__(out self, *, events: UInt32, data: UInt64):
        self.events = events
        self._data_lo = UInt32(data & 0xFFFF_FFFF)
        self._data_hi = UInt32(data >> 32)

    @always_inline
    def data(self) -> UInt64:
        return UInt64(self._data_lo) | (UInt64(self._data_hi) << 32)
