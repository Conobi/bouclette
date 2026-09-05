from std.sys.info import size_of

comptime IORING_SETUP_IOPOLL = 1
comptime IORING_SETUP_SQPOLL = 2
comptime IORING_SETUP_SQ_AFF = 4
comptime IORING_SETUP_CQSIZE = 8
comptime IORING_SETUP_CLAMP = 16
comptime IORING_SETUP_ATTACH_WQ = 32
comptime IORING_SETUP_R_DISABLED = 64
comptime IORING_SETUP_SUBMIT_ALL = 128
comptime IORING_SETUP_COOP_TASKRUN = 256
comptime IORING_SETUP_TASKRUN_FLAG = 512
comptime IORING_SETUP_SQE128 = 1024
comptime IORING_SETUP_CQE32 = 2048
comptime IORING_SETUP_SINGLE_ISSUER = 4096
comptime IORING_SETUP_DEFER_TASKRUN = 8192
comptime IORING_SETUP_NO_MMAP = 16384
comptime IORING_SETUP_REGISTERED_FD_ONLY = 32768
comptime IORING_SETUP_NO_SQARRAY = 65536
comptime IORING_URING_CMD_FIXED = 1
comptime IORING_URING_CMD_MASK = 1
comptime IORING_FSYNC_DATASYNC = 1

comptime IORING_POLL_ADD_MULTI = 1
comptime IORING_POLL_UPDATE_EVENTS = 2
comptime IORING_POLL_UPDATE_USER_DATA = 4
comptime IORING_POLL_ADD_LEVEL = 8
comptime IORING_ASYNC_CANCEL_ALL = 1
comptime IORING_ASYNC_CANCEL_FD = 2
comptime IORING_ASYNC_CANCEL_ANY = 4
comptime IORING_ASYNC_CANCEL_FD_FIXED = 8
comptime IORING_ASYNC_CANCEL_USERDATA = 16
comptime IORING_ASYNC_CANCEL_OP = 32
comptime IORING_RECVSEND_POLL_FIRST = 1
comptime IORING_RECV_MULTISHOT = 2
comptime IORING_RECVSEND_FIXED_BUF = 4
comptime IORING_SEND_ZC_REPORT_USAGE = 8
comptime IORING_NOTIF_USAGE_ZC_COPIED = 2147483648
comptime IORING_ACCEPT_MULTISHOT = 1
comptime IORING_MSG_RING_CQE_SKIP = 1
comptime IORING_MSG_RING_FLAGS_PASS = 2
comptime IORING_CQE_F_BUFFER = 1
comptime IORING_CQE_F_MORE = 2
comptime IORING_CQE_F_SOCK_NONEMPTY = 4
comptime IORING_CQE_F_NOTIF = 8

comptime IORING_OFF_SQ_RING = 0
comptime IORING_OFF_CQ_RING = 134217728
comptime IORING_OFF_SQES = 268435456
comptime IORING_SQ_NEED_WAKEUP = 1
comptime IORING_SQ_CQ_OVERFLOW = 2
comptime IORING_SQ_TASKRUN = 4
comptime IORING_CQ_EVENTFD_DISABLED = 1
comptime IORING_ENTER_GETEVENTS = 1
comptime IORING_ENTER_SQ_WAKEUP = 2
comptime IORING_ENTER_SQ_WAIT = 4
comptime IORING_ENTER_EXT_ARG = 8
comptime IORING_ENTER_REGISTERED_RING = 16

comptime IORING_FEAT_SINGLE_MMAP = 1
comptime IORING_FEAT_NODROP = 2
comptime IORING_FEAT_SUBMIT_STABLE = 4
comptime IORING_FEAT_RW_CUR_POS = 8
comptime IORING_FEAT_CUR_PERSONALITY = 16
comptime IORING_FEAT_FAST_POLL = 32
comptime IORING_FEAT_POLL_32BITS = 64
comptime IORING_FEAT_SQPOLL_NONFIXED = 128
comptime IORING_FEAT_EXT_ARG = 256
comptime IORING_FEAT_NATIVE_WORKERS = 512
comptime IORING_FEAT_RSRC_TAGS = 1024
comptime IORING_FEAT_CQE_SKIP = 2048
comptime IORING_FEAT_LINKED_FILE = 4096
comptime IORING_FEAT_REG_REG_RING = 8192

comptime IORING_CQE_BUFFER_SHIFT = 16
comptime IORING_REGISTER_BUFFERS = 0
comptime IORING_UNREGISTER_BUFFERS = 1
comptime IORING_REGISTER_FILES = 2
comptime IORING_UNREGISTER_FILES = 3
comptime IORING_REGISTER_EVENTFD = 4
comptime IORING_UNREGISTER_EVENTFD = 5
comptime IORING_REGISTER_FILES_UPDATE = 6
comptime IORING_REGISTER_EVENTFD_ASYNC = 7
comptime IORING_REGISTER_PROBE = 8
# io_uring_probe_op.flags bit: the opcode is supported by this kernel.
comptime IO_URING_OP_SUPPORTED = 1
comptime IORING_REGISTER_PERSONALITY = 9
comptime IORING_UNREGISTER_PERSONALITY = 10
comptime IORING_REGISTER_RESTRICTIONS = 11
comptime IORING_REGISTER_ENABLE_RINGS = 12
comptime IORING_REGISTER_FILES2 = 13
comptime IORING_REGISTER_FILES_UPDATE2 = 14
comptime IORING_REGISTER_BUFFERS2 = 15
comptime IORING_REGISTER_BUFFERS_UPDATE = 16
comptime IORING_REGISTER_IOWQ_AFF = 17
comptime IORING_UNREGISTER_IOWQ_AFF = 18
comptime IORING_REGISTER_IOWQ_MAX_WORKERS = 19
comptime IORING_REGISTER_RING_FDS = 20
comptime IORING_UNREGISTER_RING_FDS = 21
comptime IORING_REGISTER_PBUF_RING = 22
comptime IORING_UNREGISTER_PBUF_RING = 23
comptime IORING_REGISTER_SYNC_CANCEL = 24
comptime IORING_REGISTER_FILE_ALLOC_RANGE = 25
comptime IORING_REGISTER_LAST = 26
comptime IORING_REGISTER_USE_REGISTERED_RING = 2147483648

comptime IOSQE_FIXED_FILE_BIT = 0
comptime IOSQE_IO_DRAIN_BIT = 1
comptime IOSQE_IO_LINK_BIT = 2
comptime IOSQE_IO_HARDLINK_BIT = 3
comptime IOSQE_ASYNC_BIT = 4
comptime IOSQE_BUFFER_SELECT_BIT = 5
comptime IOSQE_CQE_SKIP_SUCCESS_BIT = 6

comptime IORING_OP_NOP = 0
comptime IORING_OP_READV = 1
comptime IORING_OP_WRITEV = 2
comptime IORING_OP_FSYNC = 3
comptime IORING_OP_READ_FIXED = 4
comptime IORING_OP_WRITE_FIXED = 5
comptime IORING_OP_POLL_ADD = 6
comptime IORING_OP_POLL_REMOVE = 7
comptime IORING_OP_SYNC_FILE_RANGE = 8
comptime IORING_OP_SENDMSG = 9
comptime IORING_OP_RECVMSG = 10
comptime IORING_OP_TIMEOUT = 11
comptime IORING_OP_TIMEOUT_REMOVE = 12
comptime IORING_OP_ACCEPT = 13
comptime IORING_OP_ASYNC_CANCEL = 14
comptime IORING_OP_LINK_TIMEOUT = 15
comptime IORING_OP_CONNECT = 16
comptime IORING_OP_FALLOCATE = 17
comptime IORING_OP_OPENAT = 18
comptime IORING_OP_CLOSE = 19
comptime IORING_OP_FILES_UPDATE = 20
comptime IORING_OP_STATX = 21
comptime IORING_OP_READ = 22
comptime IORING_OP_WRITE = 23
comptime IORING_OP_FADVISE = 24
comptime IORING_OP_MADVISE = 25
comptime IORING_OP_SEND = 26
comptime IORING_OP_RECV = 27
comptime IORING_OP_OPENAT2 = 28
comptime IORING_OP_EPOLL_CTL = 29
comptime IORING_OP_SPLICE = 30
comptime IORING_OP_PROVIDE_BUFFERS = 31
comptime IORING_OP_REMOVE_BUFFERS = 32
comptime IORING_OP_TEE = 33
comptime IORING_OP_SHUTDOWN = 34
comptime IORING_OP_RENAMEAT = 35
comptime IORING_OP_UNLINKAT = 36
comptime IORING_OP_MKDIRAT = 37
comptime IORING_OP_SYMLINKAT = 38
comptime IORING_OP_LINKAT = 39
comptime IORING_OP_MSG_RING = 40
comptime IORING_OP_FSETXATTR = 41
comptime IORING_OP_SETXATTR = 42
comptime IORING_OP_FGETXATTR = 43
comptime IORING_OP_GETXATTR = 44
comptime IORING_OP_SOCKET = 45
comptime IORING_OP_URING_CMD = 46
comptime IORING_OP_SEND_ZC = 47
comptime IORING_OP_SENDMSG_ZC = 48
comptime IORING_OP_LAST = 49

comptime IORING_MSG_DATA = 0
comptime IORING_MSG_SEND_FD = 1


struct io_sqring_offsets(Defaultable, ImplicitlyCopyable, Movable):
    var head: UInt32
    var tail: UInt32
    var ring_mask: UInt32
    var ring_entries: UInt32
    var flags: UInt32
    var dropped: UInt32
    var array: UInt32
    var resv1: UInt32
    var user_addr: UInt64

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 40
        self.head = 0
        self.tail = 0
        self.ring_mask = 0
        self.ring_entries = 0
        self.flags = 0
        self.dropped = 0
        self.array = 0
        self.resv1 = 0
        self.user_addr = 0


struct io_cqring_offsets(Defaultable, ImplicitlyCopyable, Movable):
    var head: UInt32
    var tail: UInt32
    var ring_mask: UInt32
    var ring_entries: UInt32
    var overflow: UInt32
    var cqes: UInt32
    var flags: UInt32
    var resv1: UInt32
    var user_addr: UInt64

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 40
        self.head = 0
        self.tail = 0
        self.ring_mask = 0
        self.ring_entries = 0
        self.overflow = 0
        self.cqes = 0
        self.flags = 0
        self.resv1 = 0
        self.user_addr = 0


struct io_uring_buf(Defaultable, ImplicitlyCopyable, Movable):
    var addr: UInt64
    var len: UInt32
    var bid: UInt16
    var resv: UInt16

    @always_inline
    def __init__(out self):
        comptime assert size_of[Self]() == 16
        self.addr = 0
        self.len = 0
        self.bid = 0
        self.resv = 0
