from boucle.socle.linux.raw.ctypes import c_ushort, c_uint, c_uchar
from std.sys.info import size_of

# SOCK_* constants
comptime SOCK_STREAM = 1
comptime SOCK_DGRAM = 2
comptime SOCK_RAW = 3
comptime SOCK_RDM = 4
comptime SOCK_SEQPACKET = 5

# MSG_* constants
comptime MSG_OOB = 1
comptime MSG_PEEK = 2
comptime MSG_DONTROUTE = 4
comptime MSG_CTRUNC = 8
comptime MSG_PROBE = 16
comptime MSG_TRUNC = 32
comptime MSG_DONTWAIT = 64
comptime MSG_EOR = 128
comptime MSG_WAITALL = 256
comptime MSG_FIN = 512
comptime MSG_SYN = 1024
comptime MSG_CONFIRM = 2048
comptime MSG_RST = 4096
comptime MSG_ERRQUEUE = 8192
comptime MSG_NOSIGNAL = 16384
comptime MSG_MORE = 32768
comptime MSG_CMSG_CLOEXEC = 1073741824

# AF_* constants
comptime AF_UNSPEC = 0
comptime AF_UNIX = 1
comptime AF_INET = 2
comptime AF_AX25 = 3
comptime AF_IPX = 4
comptime AF_APPLETALK = 5
comptime AF_NETROM = 6
comptime AF_BRIDGE = 7
comptime AF_ATMPVC = 8
comptime AF_X25 = 9
comptime AF_INET6 = 10
comptime AF_ROSE = 11
comptime AF_DECnet = 12
comptime AF_NETBEUI = 13
comptime AF_SECURITY = 14
comptime AF_KEY = 15
comptime AF_NETLINK = 16
comptime AF_PACKET = 17
comptime AF_ASH = 18
comptime AF_ECONET = 19
comptime AF_ATMSVC = 20
comptime AF_RDS = 21
comptime AF_SNA = 22
comptime AF_IRDA = 23
comptime AF_PPPOX = 24
comptime AF_WANPIPE = 25
comptime AF_LLC = 26
comptime AF_CAN = 29
comptime AF_TIPC = 30
comptime AF_BLUETOOTH = 31
comptime AF_IUCV = 32
comptime AF_RXRPC = 33
comptime AF_ISDN = 34
comptime AF_PHONET = 35
comptime AF_IEEE802154 = 36
comptime AF_CAIF = 37
comptime AF_ALG = 38
comptime AF_NFC = 39
comptime AF_VSOCK = 40
comptime AF_KCM = 41
comptime AF_QIPCRTR = 42
comptime AF_SMC = 43
comptime AF_XDP = 44
comptime AF_MCTP = 45
comptime AF_MAX = 46

# IPPROTO_* constants
comptime IPPROTO_IP = 0
comptime IPPROTO_ICMP = 1
comptime IPPROTO_IGMP = 2
comptime IPPROTO_IPIP = 4
comptime IPPROTO_TCP = 6
comptime IPPROTO_EGP = 8
comptime IPPROTO_PUP = 12
comptime IPPROTO_UDP = 17
comptime IPPROTO_IDP = 22
comptime IPPROTO_TP = 29
comptime IPPROTO_DCCP = 33
comptime IPPROTO_IPV6 = 41
comptime IPPROTO_ROUTING = 43
comptime IPPROTO_FRAGMENT = 44
comptime IPPROTO_RSVP = 46
comptime IPPROTO_GRE = 47
comptime IPPROTO_ESP = 50
comptime IPPROTO_AH = 51
comptime IPPROTO_ICMPV6 = 58
comptime IPPROTO_NONE = 59
comptime IPPROTO_DSTOPTS = 60
comptime IPPROTO_MTP = 92
comptime IPPROTO_BEETPH = 94
comptime IPPROTO_ENCAP = 98
comptime IPPROTO_PIM = 103
comptime IPPROTO_COMP = 108
comptime IPPROTO_L2TP = 115
comptime IPPROTO_SCTP = 132
comptime IPPROTO_MH = 135
comptime IPPROTO_UDPLITE = 136
comptime IPPROTO_MPLS = 137
comptime IPPROTO_ETHERNET = 143
comptime IPPROTO_RAW = 255
comptime IPPROTO_MPTCP = 262
comptime IPPROTO_MAX = 263
comptime IPPROTO_HOPOPTS = 0

# SOL_* and socket option constants
comptime SOL_SOCKET = 1
comptime SOL_IP = 0
comptime SOL_IPV6 = 41
comptime SOL_UDP = 17
comptime SO_REUSEADDR = 2
comptime SO_ERROR = 4
comptime SO_SNDBUF = 7
comptime SO_RCVBUF = 8
comptime SO_REUSEPORT = 15
comptime SO_RCVTIMEO = 20
comptime SO_SNDTIMEO = 21
comptime IP_PKTINFO = 8
comptime IPV6_V6ONLY = 26
comptime IPV6_RECVPKTINFO = 49
comptime IP_TOS = 1
comptime IP_RECVTOS = 13
comptime IPV6_TCLASS = 67
comptime IPV6_RECVTCLASS = 66
comptime UDP_GRO = 104
comptime UDP_SEGMENT = 103

# SHUT_* constants
comptime SHUT_RD = 0
comptime SHUT_WR = 1
comptime SHUT_RDWR = 2

# Kernel type aliases
comptime __u8 = c_uchar
comptime __u16 = c_ushort
comptime __u32 = c_uint

comptime __be16 = __u16
comptime __be32 = __u32

comptime socklen_t = c_uint

comptime __kernel_sa_family_t = c_ushort


struct in_addr(ImplicitlyCopyable, Movable):
    var s_addr: __be32

    @always_inline
    def __init__(out self, s_addr: __be32 = 0):
        comptime assert size_of[Self]() == 4
        self.s_addr = s_addr


# sockaddr_in is 16 bytes on x86_64.
# Fields are flattened (sin_addr inlined as __be32).
@fieldwise_init
struct sockaddr_in(ImplicitlyCopyable, Movable):
    var sin_family: __kernel_sa_family_t
    var sin_port: __be16
    var sin_addr_s_addr: __be32  # in_addr.s_addr inlined
    var _pad0: UInt32
    var _pad1: UInt32

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 16
        self.sin_family = 0
        self.sin_port = 0
        self.sin_addr_s_addr = 0
        self._pad0 = 0
        self._pad1 = 0


# in6_addr is 16 bytes. Four UInt32 fields give 4-byte alignment.
@fieldwise_init
struct in6_addr(ImplicitlyCopyable, Movable):
    var a: UInt32
    var b: UInt32
    var c: UInt32
    var d: UInt32

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 16
        self.a = 0
        self.b = 0
        self.c = 0
        self.d = 0


# sockaddr_in6 is 28 bytes on x86_64.
# sin6_addr fields are inlined.
@fieldwise_init
struct sockaddr_in6(ImplicitlyCopyable, Movable):
    var sin6_family: c_ushort
    var sin6_port: __be16
    var sin6_flowinfo: __be32
    var sin6_addr_a: UInt32  # in6_addr bytes 0-3
    var sin6_addr_b: UInt32  # in6_addr bytes 4-7
    var sin6_addr_c: UInt32  # in6_addr bytes 8-11
    var sin6_addr_d: UInt32  # in6_addr bytes 12-15
    var sin6_scope_id: __u32

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 28
        self.sin6_family = 0
        self.sin6_port = 0
        self.sin6_flowinfo = 0
        self.sin6_addr_a = 0
        self.sin6_addr_b = 0
        self.sin6_addr_c = 0
        self.sin6_addr_d = 0
        self.sin6_scope_id = 0


@fieldwise_init
struct iovec(ImplicitlyCopyable, Movable):
    var iov_base: UInt64  # void*
    var iov_len: UInt64   # size_t

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 16
        self.iov_base = 0
        self.iov_len = 0


# msghdr is 56 bytes on x86_64
# offsets: msg_name=0, msg_namelen=8, [pad=12], msg_iov=16, msg_iovlen=24,
#          msg_control=32, msg_controllen=40, msg_flags=48, [pad=52]
@fieldwise_init
struct msghdr(ImplicitlyCopyable, Movable):
    var msg_name: UInt64        # void* -- sockaddr pointer
    var msg_namelen: UInt32     # socklen_t
    var _pad0: UInt32           # alignment padding (offsets 12-15)
    var msg_iov: UInt64         # struct iovec* pointer
    var msg_iovlen: UInt64      # size_t -- number of iovecs
    var msg_control: UInt64     # void* -- cmsg buffer pointer
    var msg_controllen: UInt64  # size_t -- cmsg buffer length
    var msg_flags: Int32        # int
    var _pad1: UInt32           # alignment padding (offsets 52-55)

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 56
        self.msg_name = 0
        self.msg_namelen = 0
        self._pad0 = 0
        self.msg_iov = 0
        self.msg_iovlen = 0
        self.msg_control = 0
        self.msg_controllen = 0
        self.msg_flags = 0
        self._pad1 = 0


# cmsghdr is 16 bytes -- cmsg_len is size_t (8 bytes on x86_64)
@fieldwise_init
struct cmsghdr(ImplicitlyCopyable, Movable):
    var cmsg_len: UInt64   # size_t -- total length including header and data
    var cmsg_level: Int32  # int -- originating protocol
    var cmsg_type: Int32   # int -- protocol-specific type

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 16
        self.cmsg_len = 0
        self.cmsg_level = 0
        self.cmsg_type = 0


# in_pktinfo is 12 bytes (flattened: in_addr fields inlined)
# offsets: ipi_ifindex=0, ipi_spec_dst=4, ipi_addr=8
@fieldwise_init
struct in_pktinfo(ImplicitlyCopyable, Movable):
    var ipi_ifindex: Int32     # int -- interface index
    var ipi_spec_dst: __be32   # in_addr.s_addr -- local address (source)
    var ipi_addr: __be32       # in_addr.s_addr -- destination address

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 12
        self.ipi_ifindex = 0
        self.ipi_spec_dst = 0
        self.ipi_addr = 0


# in6_pktinfo is 20 bytes (flattened: in6_addr fields inlined)
# offsets: ipi6_addr=0, ipi6_ifindex=16
@fieldwise_init
struct in6_pktinfo(ImplicitlyCopyable, Movable):
    var ipi6_addr_a: UInt32    # in6_addr bytes 0-3
    var ipi6_addr_b: UInt32    # in6_addr bytes 4-7
    var ipi6_addr_c: UInt32    # in6_addr bytes 8-11
    var ipi6_addr_d: UInt32    # in6_addr bytes 12-15
    var ipi6_ifindex: UInt32   # unsigned int -- interface index

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 20
        self.ipi6_addr_a = 0
        self.ipi6_addr_b = 0
        self.ipi6_addr_c = 0
        self.ipi6_addr_d = 0
        self.ipi6_ifindex = 0
