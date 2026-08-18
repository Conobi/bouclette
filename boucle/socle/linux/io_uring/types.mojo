"""Io_uring syscall wrappers and kernel type definitions.

Provides the complete set of types and syscall wrappers needed to interact
with the Linux io_uring interface: flag structs, SQE/CQE structures,
IoUringParams, and the three io_uring syscalls (setup, enter, register).
"""

from boucle.socle.linux.raw.ctypes import c_void
from boucle.socle.linux.fd import UnsafeFd, close, close_unchecked
from boucle.socle.linux.errno import is_eintr, unsafe_decode_result
from boucle.socle.linux.utils import _aligned_u64, _align_eq, _size_eq
from boucle.socle.linux.raw import (
    IORING_SETUP_IOPOLL,
    IORING_SETUP_SQPOLL,
    IORING_SETUP_SQ_AFF,
    IORING_SETUP_CQSIZE,
    IORING_SETUP_CLAMP,
    IORING_SETUP_ATTACH_WQ,
    IORING_SETUP_R_DISABLED,
    IORING_SETUP_SUBMIT_ALL,
    IORING_SETUP_COOP_TASKRUN,
    IORING_SETUP_TASKRUN_FLAG,
    IORING_SETUP_SQE128,
    IORING_SETUP_CQE32,
    IORING_SETUP_SINGLE_ISSUER,
    IORING_SETUP_DEFER_TASKRUN,
    IORING_SETUP_NO_MMAP,
    IORING_SETUP_REGISTERED_FD_ONLY,
    IORING_SETUP_NO_SQARRAY,
    IORING_FSYNC_DATASYNC,
    IORING_POLL_ADD_MULTI,
    IORING_POLL_UPDATE_EVENTS,
    IORING_POLL_UPDATE_USER_DATA,
    IORING_POLL_ADD_LEVEL,
    IORING_RECVSEND_POLL_FIRST,
    IORING_RECV_MULTISHOT,
    IORING_RECVSEND_FIXED_BUF,
    IORING_SEND_ZC_REPORT_USAGE,
    IORING_ACCEPT_MULTISHOT,
    IORING_MSG_RING_CQE_SKIP,
    IORING_MSG_RING_FLAGS_PASS,
    IORING_CQE_F_BUFFER,
    IORING_CQE_F_MORE,
    IORING_CQE_F_SOCK_NONEMPTY,
    IORING_CQE_F_NOTIF,
    IORING_SQ_NEED_WAKEUP,
    IORING_SQ_CQ_OVERFLOW,
    IORING_SQ_TASKRUN,
    IORING_ENTER_GETEVENTS,
    IORING_ENTER_SQ_WAKEUP,
    IORING_ENTER_SQ_WAIT,
    IORING_ENTER_EXT_ARG,
    IORING_ENTER_REGISTERED_RING,
    IORING_FEAT_SINGLE_MMAP,
    IORING_FEAT_NODROP,
    IORING_FEAT_SUBMIT_STABLE,
    IORING_FEAT_RW_CUR_POS,
    IORING_FEAT_CUR_PERSONALITY,
    IORING_FEAT_FAST_POLL,
    IORING_FEAT_POLL_32BITS,
    IORING_FEAT_SQPOLL_NONFIXED,
    IORING_FEAT_EXT_ARG,
    IORING_FEAT_NATIVE_WORKERS,
    IORING_FEAT_RSRC_TAGS,
    IORING_FEAT_CQE_SKIP,
    IORING_FEAT_LINKED_FILE,
    IORING_FEAT_REG_REG_RING,
    IORING_REGISTER_BUFFERS,
    IORING_UNREGISTER_BUFFERS,
    IORING_REGISTER_FILES,
    IORING_UNREGISTER_FILES,
    IORING_REGISTER_EVENTFD,
    IORING_UNREGISTER_EVENTFD,
    IORING_REGISTER_FILES_UPDATE,
    IORING_REGISTER_EVENTFD_ASYNC,
    IORING_REGISTER_PROBE,
    IORING_REGISTER_PERSONALITY,
    IORING_UNREGISTER_PERSONALITY,
    IORING_REGISTER_RESTRICTIONS,
    IORING_REGISTER_ENABLE_RINGS,
    IORING_REGISTER_FILES2,
    IORING_REGISTER_FILES_UPDATE2,
    IORING_REGISTER_BUFFERS2,
    IORING_REGISTER_BUFFERS_UPDATE,
    IORING_REGISTER_IOWQ_AFF,
    IORING_UNREGISTER_IOWQ_AFF,
    IORING_REGISTER_IOWQ_MAX_WORKERS,
    IORING_REGISTER_RING_FDS,
    IORING_UNREGISTER_RING_FDS,
    IORING_REGISTER_PBUF_RING,
    IORING_UNREGISTER_PBUF_RING,
    IORING_REGISTER_SYNC_CANCEL,
    IORING_REGISTER_FILE_ALLOC_RANGE,
    IORING_REGISTER_USE_REGISTERED_RING,
    IOSQE_FIXED_FILE_BIT,
    IOSQE_IO_DRAIN_BIT,
    IOSQE_IO_LINK_BIT,
    IOSQE_IO_HARDLINK_BIT,
    IOSQE_ASYNC_BIT,
    IOSQE_BUFFER_SELECT_BIT,
    IOSQE_CQE_SKIP_SUCCESS_BIT,
    IORING_OP_NOP,
    IORING_OP_READV,
    IORING_OP_WRITEV,
    IORING_OP_FSYNC,
    IORING_OP_READ_FIXED,
    IORING_OP_WRITE_FIXED,
    IORING_OP_POLL_ADD,
    IORING_OP_POLL_REMOVE,
    IORING_OP_SYNC_FILE_RANGE,
    IORING_OP_SENDMSG,
    IORING_OP_RECVMSG,
    IORING_OP_TIMEOUT,
    IORING_OP_TIMEOUT_REMOVE,
    IORING_OP_ACCEPT,
    IORING_OP_ASYNC_CANCEL,
    IORING_OP_LINK_TIMEOUT,
    IORING_OP_CONNECT,
    IORING_OP_FALLOCATE,
    IORING_OP_OPENAT,
    IORING_OP_CLOSE,
    IORING_OP_FILES_UPDATE,
    IORING_OP_STATX,
    IORING_OP_READ,
    IORING_OP_WRITE,
    IORING_OP_FADVISE,
    IORING_OP_MADVISE,
    IORING_OP_SEND,
    IORING_OP_RECV,
    IORING_OP_OPENAT2,
    IORING_OP_EPOLL_CTL,
    IORING_OP_SPLICE,
    IORING_OP_PROVIDE_BUFFERS,
    IORING_OP_REMOVE_BUFFERS,
    IORING_OP_TEE,
    IORING_OP_SHUTDOWN,
    IORING_OP_RENAMEAT,
    IORING_OP_UNLINKAT,
    IORING_OP_MKDIRAT,
    IORING_OP_SYMLINKAT,
    IORING_OP_LINKAT,
    IORING_OP_MSG_RING,
    IORING_OP_FSETXATTR,
    IORING_OP_SETXATTR,
    IORING_OP_FGETXATTR,
    IORING_OP_GETXATTR,
    IORING_OP_SOCKET,
    IORING_OP_URING_CMD,
    IORING_OP_SEND_ZC,
    IORING_OP_SENDMSG_ZC,
    IORING_MSG_DATA,
    IORING_MSG_SEND_FD,
    EINVAL,
    io_sqring_offsets,
    io_cqring_offsets,
)
from boucle.socle.linux.raw import (
    __NR_io_uring_setup,
    __NR_io_uring_register,
    __NR_io_uring_enter,
)
from boucle.socle.linux.raw import syscall
from boucle.socle.linux.raw.utils import DTypeArray
from boucle.socle.ptr import null_ptr
from std.memory import Pointer


# ===----------------------------------------------------------------------=== #
# Flag structs
# ===----------------------------------------------------------------------=== #


struct IoUringSetupFlags(TrivialRegisterPassable, Defaultable, Boolable):
    comptime IOPOLL = Self(IORING_SETUP_IOPOLL)
    comptime SQPOLL = Self(IORING_SETUP_SQPOLL)
    comptime SQ_AFF = Self(IORING_SETUP_SQ_AFF)
    comptime CQSIZE = Self(IORING_SETUP_CQSIZE)
    comptime CLAMP = Self(IORING_SETUP_CLAMP)
    comptime ATTACH_WQ = Self(IORING_SETUP_ATTACH_WQ)
    comptime R_DISABLED = Self(IORING_SETUP_R_DISABLED)
    comptime SUBMIT_ALL = Self(IORING_SETUP_SUBMIT_ALL)
    comptime COOP_TASKRUN = Self(IORING_SETUP_COOP_TASKRUN)
    comptime TASKRUN_FLAG = Self(IORING_SETUP_TASKRUN_FLAG)
    comptime SQE128 = Self(IORING_SETUP_SQE128)
    comptime CQE32 = Self(IORING_SETUP_CQE32)
    comptime SINGLE_ISSUER = Self(IORING_SETUP_SINGLE_ISSUER)
    comptime DEFER_TASKRUN = Self(IORING_SETUP_DEFER_TASKRUN)
    comptime NO_MMAP = Self(IORING_SETUP_NO_MMAP)
    comptime REGISTERED_FD_ONLY = Self(IORING_SETUP_REGISTERED_FD_ONLY)
    comptime NO_SQARRAY = Self(IORING_SETUP_NO_SQARRAY)

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value

    @always_inline("nodebug")
    def __eq__(self, rhs: Self) -> Bool:
        """Compares one IoUringSetupFlags to another for equality.

        Args:
            rhs: The RHS value.

        Returns:
            True if the IoUringSetupFlags are the same and False otherwise.
        """
        return self.value == rhs.value

    @always_inline("nodebug")
    def __ne__(self, rhs: Self) -> Bool:
        """Compares one IoUringSetupFlags to another for inequality.

        Args:
            rhs: The RHS value.

        Returns:
            False if the IoUringSetupFlags are the same and True otherwise.
        """
        return self.value != rhs.value

    @always_inline("nodebug")
    def __or__(self, rhs: Self) -> Self:
        """Returns `self | rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self | rhs`.
        """
        return self.value | rhs.value

    @always_inline("nodebug")
    def __ior__(mut self, rhs: Self):
        """Computes `self | rhs` and saves the result in self.

        Args:
            rhs: The RHS value.
        """
        self = self | rhs

    @always_inline("nodebug")
    def __and__(self, rhs: Self) -> Self:
        """Returns `self & rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self & rhs`.
        """
        return self.value & rhs.value

    @always_inline("nodebug")
    def __bool__(self) -> Bool:
        """Converts this flags to Bool.

        Returns:
            False Bool value if the value is equal to 0 and True otherwise.
        """
        return self.value != 0


struct IoUringFeatureFlags(TrivialRegisterPassable, Defaultable, Boolable):
    comptime SINGLE_MMAP = Self(IORING_FEAT_SINGLE_MMAP)
    comptime NODROP = Self(IORING_FEAT_NODROP)
    comptime SUBMIT_STABLE = Self(IORING_FEAT_SUBMIT_STABLE)
    comptime RW_CUR_POS = Self(IORING_FEAT_RW_CUR_POS)
    comptime CUR_PERSONALITY = Self(IORING_FEAT_CUR_PERSONALITY)
    comptime FAST_POLL = Self(IORING_FEAT_FAST_POLL)
    comptime POLL_32BITS = Self(IORING_FEAT_POLL_32BITS)
    comptime SQPOLL_NONFIXED = Self(IORING_FEAT_SQPOLL_NONFIXED)
    comptime EXT_ARG = Self(IORING_FEAT_EXT_ARG)
    comptime NATIVE_WORKERS = Self(IORING_FEAT_NATIVE_WORKERS)
    comptime RSRC_TAGS = Self(IORING_FEAT_RSRC_TAGS)
    comptime CQE_SKIP = Self(IORING_FEAT_CQE_SKIP)
    comptime LINKED_FILE = Self(IORING_FEAT_LINKED_FILE)
    comptime REG_REG_RING = Self(IORING_FEAT_REG_REG_RING)

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value

    @always_inline("nodebug")
    def __and__(self, rhs: Self) -> Self:
        """Returns `self & rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self & rhs`.
        """
        return self.value & rhs.value

    @always_inline("nodebug")
    def __bool__(self) -> Bool:
        """Converts this flags to Bool.

        Returns:
            False Bool value if the value is equal to 0 and True otherwise.
        """
        return self.value != 0


struct IoUringRegisterOp(TrivialRegisterPassable):
    comptime REGISTER_BUFFERS = Self(unsafe_id=IORING_REGISTER_BUFFERS)
    comptime UNREGISTER_BUFFERS = Self(unsafe_id=IORING_UNREGISTER_BUFFERS)
    comptime REGISTER_FILES = Self(unsafe_id=IORING_REGISTER_FILES)
    comptime UNREGISTER_FILES = Self(unsafe_id=IORING_UNREGISTER_FILES)
    comptime REGISTER_EVENTFD = Self(unsafe_id=IORING_REGISTER_EVENTFD)
    comptime UNREGISTER_EVENTFD = Self(unsafe_id=IORING_UNREGISTER_EVENTFD)
    comptime REGISTER_FILES_UPDATE = Self(unsafe_id=IORING_REGISTER_FILES_UPDATE)
    comptime REGISTER_EVENTFD_ASYNC = Self(unsafe_id=IORING_REGISTER_EVENTFD_ASYNC)
    comptime REGISTER_PROBE = Self(unsafe_id=IORING_REGISTER_PROBE)
    comptime REGISTER_PERSONALITY = Self(unsafe_id=IORING_REGISTER_PERSONALITY)
    comptime UNREGISTER_PERSONALITY = Self(unsafe_id=IORING_UNREGISTER_PERSONALITY)
    comptime REGISTER_RESTRICTIONS = Self(unsafe_id=IORING_REGISTER_RESTRICTIONS)
    comptime REGISTER_ENABLE_RINGS = Self(unsafe_id=IORING_REGISTER_ENABLE_RINGS)
    comptime REGISTER_FILES2 = Self(unsafe_id=IORING_REGISTER_FILES2)
    comptime REGISTER_FILES_UPDATE2 = Self(unsafe_id=IORING_REGISTER_FILES_UPDATE2)
    comptime REGISTER_BUFFERS2 = Self(unsafe_id=IORING_REGISTER_BUFFERS2)
    comptime REGISTER_BUFFERS_UPDATE = Self(
        unsafe_id=IORING_REGISTER_BUFFERS_UPDATE
    )
    comptime REGISTER_IOWQ_AFF = Self(unsafe_id=IORING_REGISTER_IOWQ_AFF)
    comptime UNREGISTER_IOWQ_AFF = Self(unsafe_id=IORING_UNREGISTER_IOWQ_AFF)
    comptime REGISTER_IOWQ_MAX_WORKERS = Self(
        unsafe_id=IORING_REGISTER_IOWQ_MAX_WORKERS
    )
    comptime REGISTER_RING_FDS = Self(unsafe_id=IORING_REGISTER_RING_FDS)
    comptime UNREGISTER_RING_FDS = Self(unsafe_id=IORING_UNREGISTER_RING_FDS)
    comptime REGISTER_PBUF_RING = Self(unsafe_id=IORING_REGISTER_PBUF_RING)
    comptime UNREGISTER_PBUF_RING = Self(unsafe_id=IORING_UNREGISTER_PBUF_RING)
    comptime REGISTER_SYNC_CANCEL = Self(unsafe_id=IORING_REGISTER_SYNC_CANCEL)
    comptime REGISTER_FILE_ALLOC_RANGE = Self(
        unsafe_id=IORING_REGISTER_FILE_ALLOC_RANGE
    )

    var id: UInt32

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_id: UInt32):
        self.id = unsafe_id


struct IoUringRegisterFlags(TrivialRegisterPassable, Defaultable):
    comptime REGISTER_USE_REGISTERED_RING = Self(
        IORING_REGISTER_USE_REGISTERED_RING
    )

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value


struct IoUringSqFlags(TrivialRegisterPassable, Defaultable):
    comptime NEED_WAKEUP = UInt32(IORING_SQ_NEED_WAKEUP)
    comptime CQ_OVERFLOW = UInt32(IORING_SQ_CQ_OVERFLOW)
    comptime TASKRUN = UInt32(IORING_SQ_TASKRUN)

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0


struct IoUringEnterFlags(TrivialRegisterPassable, Defaultable):
    comptime GETEVENTS = Self(IORING_ENTER_GETEVENTS)
    comptime SQ_WAKEUP = Self(IORING_ENTER_SQ_WAKEUP)
    comptime SQ_WAIT = Self(IORING_ENTER_SQ_WAIT)
    comptime EXT_ARG = Self(IORING_ENTER_EXT_ARG)
    comptime REGISTERED_RING = Self(IORING_ENTER_REGISTERED_RING)

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value

    @always_inline("nodebug")
    def __or__(self, rhs: Self) -> Self:
        """Returns `self | rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self | rhs`.
        """
        return self.value | rhs.value

    @always_inline("nodebug")
    def __ior__(mut self, rhs: Self):
        """Computes `self | rhs` and saves the result in self.

        Args:
            rhs: The RHS value.
        """
        self = self | rhs


struct IoUringSqeFlags(TrivialRegisterPassable, Defaultable):
    comptime FIXED_FILE = Self(1 << IOSQE_FIXED_FILE_BIT)
    comptime IO_DRAIN = Self(1 << IOSQE_IO_DRAIN_BIT)
    comptime IO_LINK = Self(1 << IOSQE_IO_LINK_BIT)
    comptime IO_HARDLINK = Self(1 << IOSQE_IO_HARDLINK_BIT)
    comptime ASYNC = Self(1 << IOSQE_ASYNC_BIT)
    comptime BUFFER_SELECT = Self(1 << IOSQE_BUFFER_SELECT_BIT)
    comptime CQE_SKIP_SUCCESS = Self(1 << IOSQE_CQE_SKIP_SUCCESS_BIT)

    var value: UInt8

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt8):
        self.value = value

    @always_inline("nodebug")
    def __or__(self, rhs: Self) -> Self:
        """Returns `self | rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self | rhs`.
        """
        return self.value | rhs.value

    @always_inline("nodebug")
    def __ior__(mut self, rhs: Self):
        """Computes `self | rhs` and saves the result in self.

        Args:
            rhs: The RHS value.
        """
        self = self | rhs


struct IoUringCqeFlags(TrivialRegisterPassable, Defaultable, Boolable):
    comptime BUFFER = Self(IORING_CQE_F_BUFFER)
    comptime MORE = Self(IORING_CQE_F_MORE)
    comptime SOCK_NONEMPTY = Self(IORING_CQE_F_SOCK_NONEMPTY)
    comptime NOTIF = Self(IORING_CQE_F_NOTIF)

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value

    @always_inline("nodebug")
    def __and__(self, rhs: Self) -> Self:
        """Returns `self & rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self & rhs`.
        """
        return self.value & rhs.value

    @always_inline("nodebug")
    def __bool__(self) -> Bool:
        """Converts this flags to Bool.

        Returns:
            False Bool value if the value is equal to 0 and True otherwise.
        """
        return self.value != 0

    @always_inline("nodebug")
    def __rshift__(self, rhs: Int) -> Self:
        """Returns `self >> rhs`.

        Args:
            rhs: The RHS value.

        Returns:
            `self >> rhs`.
        """
        return self.value >> UInt32(rhs)


struct IoUringOp(TrivialRegisterPassable):
    comptime NOP = Self(unsafe_id=IORING_OP_NOP)
    comptime READV = Self(unsafe_id=IORING_OP_READV)
    comptime WRITEV = Self(unsafe_id=IORING_OP_WRITEV)
    comptime FSYNC = Self(unsafe_id=IORING_OP_FSYNC)
    comptime READ_FIXED = Self(unsafe_id=IORING_OP_READ_FIXED)
    comptime WRITE_FIXED = Self(unsafe_id=IORING_OP_WRITE_FIXED)
    comptime POLL_ADD = Self(unsafe_id=IORING_OP_POLL_ADD)
    comptime POLL_REMOVE = Self(unsafe_id=IORING_OP_POLL_REMOVE)
    comptime SYNC_FILE_RANGE = Self(unsafe_id=IORING_OP_SYNC_FILE_RANGE)
    comptime SENDMSG = Self(unsafe_id=IORING_OP_SENDMSG)
    comptime RECVMSG = Self(unsafe_id=IORING_OP_RECVMSG)
    comptime TIMEOUT = Self(unsafe_id=IORING_OP_TIMEOUT)
    comptime TIMEOUT_REMOVE = Self(unsafe_id=IORING_OP_TIMEOUT_REMOVE)
    comptime ACCEPT = Self(unsafe_id=IORING_OP_ACCEPT)
    comptime ASYNC_CANCEL = Self(unsafe_id=IORING_OP_ASYNC_CANCEL)
    comptime LINK_TIMEOUT = Self(unsafe_id=IORING_OP_LINK_TIMEOUT)
    comptime CONNECT = Self(unsafe_id=IORING_OP_CONNECT)
    comptime FALLOCATE = Self(unsafe_id=IORING_OP_FALLOCATE)
    comptime OPENAT = Self(unsafe_id=IORING_OP_OPENAT)
    comptime CLOSE = Self(unsafe_id=IORING_OP_CLOSE)
    comptime FILES_UPDATE = Self(unsafe_id=IORING_OP_FILES_UPDATE)
    comptime STATX = Self(unsafe_id=IORING_OP_STATX)
    comptime READ = Self(unsafe_id=IORING_OP_READ)
    comptime WRITE = Self(unsafe_id=IORING_OP_WRITE)
    comptime FADVISE = Self(unsafe_id=IORING_OP_FADVISE)
    comptime MADVISE = Self(unsafe_id=IORING_OP_MADVISE)
    comptime SEND = Self(unsafe_id=IORING_OP_SEND)
    comptime RECV = Self(unsafe_id=IORING_OP_RECV)
    comptime OPENAT2 = Self(unsafe_id=IORING_OP_OPENAT2)
    comptime EPOLL_CTL = Self(unsafe_id=IORING_OP_EPOLL_CTL)
    comptime SPLICE = Self(unsafe_id=IORING_OP_SPLICE)
    comptime PROVIDE_BUFFERS = Self(unsafe_id=IORING_OP_PROVIDE_BUFFERS)
    comptime REMOVE_BUFFERS = Self(unsafe_id=IORING_OP_REMOVE_BUFFERS)
    comptime TEE = Self(unsafe_id=IORING_OP_TEE)
    comptime SHUTDOWN = Self(unsafe_id=IORING_OP_SHUTDOWN)
    comptime RENAMEAT = Self(unsafe_id=IORING_OP_RENAMEAT)
    comptime UNLINKAT = Self(unsafe_id=IORING_OP_UNLINKAT)
    comptime MKDIRAT = Self(unsafe_id=IORING_OP_MKDIRAT)
    comptime SYMLINKAT = Self(unsafe_id=IORING_OP_SYMLINKAT)
    comptime LINKAT = Self(unsafe_id=IORING_OP_LINKAT)
    comptime MSG_RING = Self(unsafe_id=IORING_OP_MSG_RING)
    comptime FSETXATTR = Self(unsafe_id=IORING_OP_FSETXATTR)
    comptime SETXATTR = Self(unsafe_id=IORING_OP_SETXATTR)
    comptime FGETXATTR = Self(unsafe_id=IORING_OP_FGETXATTR)
    comptime GETXATTR = Self(unsafe_id=IORING_OP_GETXATTR)
    comptime SOCKET = Self(unsafe_id=IORING_OP_SOCKET)
    comptime URING_CMD = Self(unsafe_id=IORING_OP_URING_CMD)
    comptime SEND_ZC = Self(unsafe_id=IORING_OP_SEND_ZC)
    comptime SENDMSG_ZC = Self(unsafe_id=IORING_OP_SENDMSG_ZC)

    var id: UInt8

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_id: UInt8):
        self.id = unsafe_id


struct IoUringFsyncFlags(TrivialRegisterPassable, Defaultable):
    comptime DATASYNC = Self(IORING_FSYNC_DATASYNC)

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value


struct IoUringMsgRingCmds(TrivialRegisterPassable):
    comptime DATA = Self(unsafe_id=IORING_MSG_DATA)
    comptime SEND_FD = Self(unsafe_id=IORING_MSG_SEND_FD)

    var id: UInt64

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_id: UInt64):
        self.id = unsafe_id


struct IoUringPollFlags(TrivialRegisterPassable, Defaultable):
    comptime ADD_MULTI = Self(IORING_POLL_ADD_MULTI)
    comptime UPDATE_EVENTS = Self(IORING_POLL_UPDATE_EVENTS)
    comptime UPDATE_USER_DATA = Self(IORING_POLL_UPDATE_USER_DATA)
    comptime ADD_LEVEL = Self(IORING_POLL_ADD_LEVEL)

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value


struct IoUringSendFlags(TrivialRegisterPassable, Defaultable):
    comptime POLL_FIRST = Self(IORING_RECVSEND_POLL_FIRST)
    comptime FIXED_BUF = Self(IORING_RECVSEND_FIXED_BUF)
    comptime ZC_REPORT_USAGE = Self(IORING_SEND_ZC_REPORT_USAGE)

    var value: UInt16

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt16):
        self.value = value


struct IoUringRecvFlags(TrivialRegisterPassable, Defaultable):
    comptime POLL_FIRST = Self(IORING_RECVSEND_POLL_FIRST)
    comptime MULTISHOT = Self(IORING_RECV_MULTISHOT)
    comptime FIXED_BUF = Self(IORING_RECVSEND_FIXED_BUF)

    var value: UInt16

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt16):
        self.value = value


struct IoUringAcceptFlags(TrivialRegisterPassable, Defaultable):
    comptime MULTISHOT = Self(IORING_ACCEPT_MULTISHOT)

    var value: UInt16

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt16):
        self.value = value


struct IoUringMsgRingFlags(TrivialRegisterPassable, Defaultable):
    comptime CQE_SKIP = Self(IORING_MSG_RING_CQE_SKIP)
    comptime FLAGS_PASS = Self(IORING_MSG_RING_FLAGS_PASS)

    var value: UInt32

    @always_inline("nodebug")
    def __init__(out self):
        self.value = 0

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt32):
        self.value = value


# ===----------------------------------------------------------------------=== #
# SQE / CQE type parameters
# ===----------------------------------------------------------------------=== #


comptime SQE64 = SQE(
    id=0,
    size=64,
    align=8,
    array_size=0,
    setup_flags=IoUringSetupFlags(),
)

comptime SQE128 = SQE(
    id=1,
    size=128,
    align=8,
    array_size=64,
    setup_flags=IoUringSetupFlags.SQE128,
)


@__nonmaterializable(NoneType)
struct SQE(TrivialRegisterPassable):
    var id: UInt8
    var size: Int
    var align: Int
    var array_size: Int
    var setup_flags: IoUringSetupFlags

    @always_inline
    def __init__(
        out self,
        *,
        id: UInt8,
        size: Int,
        align: Int,
        array_size: Int,
        setup_flags: IoUringSetupFlags,
    ):
        self.id = id
        self.size = size
        self.align = align
        self.array_size = array_size
        self.setup_flags = setup_flags

    @always_inline
    def __is__(self, rhs: Self) -> Bool:
        """Defines whether one SQE has the same identity as another.

        Args:
            rhs: The SQE to compare against.

        Returns:
            True if the SQEs have the same identity, False otherwise.
        """
        return (
            self.id == rhs.id
            and self.size == rhs.size
            and self.align == rhs.align
            and self.array_size == rhs.array_size
            and self.setup_flags == rhs.setup_flags
        )


comptime CQE16 = CQE(
    id=0,
    size=16,
    align=8,
    array_size=0,
    rings_size=64,
    setup_flags=IoUringSetupFlags(),
)


comptime CQE32 = CQE(
    id=1,
    size=32,
    align=8,
    array_size=2,
    rings_size=64 * 2,
    setup_flags=IoUringSetupFlags.CQE32,
)


comptime CQE_SIZE_DEFAULT = CQE16.size
comptime CQE_SIZE_MAX = CQE32.size


@__nonmaterializable(NoneType)
struct CQE(TrivialRegisterPassable):
    var id: UInt8
    var size: Int
    var align: Int
    var array_size: Int
    var rings_size: Int
    """For the size of the rings, we perform calculations in the same way as the kernel.
    [Linux]: https://github.com/torvalds/linux/blob/v6.7/io_uring/io_uring.c#L2804.
    [Linux]: https://github.com/torvalds/linux/blob/v6.7/include/linux/io_uring_types.h#L83.
    """
    var setup_flags: IoUringSetupFlags

    @always_inline
    def __init__(
        out self,
        *,
        id: UInt8,
        size: Int,
        align: Int,
        array_size: Int,
        rings_size: Int,
        setup_flags: IoUringSetupFlags,
    ):
        self.id = id
        self.size = size
        self.align = align
        self.array_size = array_size
        self.rings_size = rings_size
        self.setup_flags = setup_flags

    @always_inline
    def __is__(self, rhs: Self) -> Bool:
        """Defines whether one CQE has the same identity as another.

        Args:
            rhs: The CQE to compare against.

        Returns:
            True if the CQEs have the same identity, False otherwise.
        """
        return (
            self.id == rhs.id
            and self.size == rhs.size
            and self.align == rhs.align
            and self.array_size == rhs.array_size
            and self.rings_size == rhs.rings_size
            and self.setup_flags == rhs.setup_flags
        )


# ===----------------------------------------------------------------------=== #
# SQE / CQE structs
# ===----------------------------------------------------------------------=== #


struct addr3_struct(Defaultable, ImplicitlyCopyable, Movable):
    var addr3: UInt64
    var __pad2: DTypeArray[DType.uint64, 1]

    @always_inline
    def __init__(out self):
        self.addr3 = 0
        self.__pad2 = DTypeArray[DType.uint64, 1]()


struct Sqe[type: SQE](ImplicitlyCopyable, Movable):
    """Submission queue entry.
    [Linux]: https://github.com/torvalds/linux/blob/v6.7/include/uapi/linux/io_uring.h#L30.
    """

    comptime Array = DTypeArray[DType.uint8, Self.type.array_size]

    var opcode: IoUringOp
    var flags: IoUringSqeFlags
    var ioprio: UInt16
    var fd: UnsafeFd
    var off_or_addr2_or_cmd_op: UInt64
    var addr_or_splice_off_in_or_msgring_cmd: UInt64
    var len_or_poll_flags: UInt32
    var op_flags: UInt32
    var user_data: UInt64
    var buf_index_or_buf_group: UInt16
    var personality: UInt16
    var splice_fd_in_or_file_index_or_optlen_or_addr_len: UInt32
    var addr3_or_optval_or_cmd: addr3_struct
    var _big_sqe: Self.Array

    @always_inline
    def cmd(
        mut self,
    ) -> ref [self.addr3_or_optval_or_cmd] DTypeArray[DType.uint8, 80] where Self == Sqe[SQE128]:
        return Pointer(to=self.addr3_or_optval_or_cmd).unsafe_bitcast[
            DTypeArray[DType.uint8, 80]
        ]()[]


struct Cqe[type: CQE](ImplicitlyCopyable, Movable):
    """Completion queue entry.
    [Linux]: https://github.com/torvalds/linux/blob/v6.7/include/uapi/linux/io_uring.h#L392.
    """

    var user_data: UInt64
    var res: Int32
    var flags: IoUringCqeFlags
    var _big_cqe: DTypeArray[DType.uint64, Self.type.array_size]

    @always_inline
    def cmd(
        self,
    ) -> ref [self._big_cqe] type_of(self._big_cqe) where Self == Cqe[CQE32]:
        return self._big_cqe


# ===----------------------------------------------------------------------=== #
# IoUringParams
# ===----------------------------------------------------------------------=== #


struct IoUringParams(Defaultable, ImplicitlyCopyable, Movable):
    var sq_entries: UInt32
    var cq_entries: UInt32
    var flags: IoUringSetupFlags
    var sq_thread_cpu: UInt32
    var sq_thread_idle: UInt32
    var features: IoUringFeatureFlags
    var wq_fd: UInt32
    var resv: DTypeArray[DType.uint32, 3]
    var sq_off: io_sqring_offsets
    var cq_off: io_cqring_offsets

    @always_inline
    def __init__(out self):
        self.sq_entries = 0
        self.cq_entries = 0
        self.flags = IoUringSetupFlags()
        self.sq_thread_cpu = 0
        self.sq_thread_idle = 0
        self.features = IoUringFeatureFlags()
        self.wq_fd = 0
        self.resv = DTypeArray[DType.uint32, 3]()
        self.sq_off = io_sqring_offsets()
        self.cq_off = io_cqring_offsets()


# ===----------------------------------------------------------------------=== #
# IoUringFileDescriptor trait + fd types
# ===----------------------------------------------------------------------=== #


trait IoUringFileDescriptor(Movable):
    comptime IS_REGISTERED: Bool
    comptime SETUP_FLAGS: IoUringSetupFlags
    comptime REGISTER_FLAGS: IoUringRegisterFlags
    comptime ENTER_FLAGS: IoUringEnterFlags
    comptime SQE_FLAGS: IoUringSqeFlags

    def unsafe_fd(self) -> UnsafeFd:
        ...


struct IoUringFd[is_registered: Bool](
    TrivialRegisterPassable,
    IoUringFileDescriptor,
):
    comptime IS_REGISTERED = Self.is_registered

    comptime SETUP_FLAGS = IoUringSetupFlags.REGISTERED_FD_ONLY | IoUringSetupFlags.NO_MMAP
        if Self.is_registered else IoUringSetupFlags()

    comptime REGISTER_FLAGS = IoUringRegisterFlags.REGISTER_USE_REGISTERED_RING
        if Self.is_registered else IoUringRegisterFlags()

    comptime ENTER_FLAGS = IoUringEnterFlags.REGISTERED_RING if Self.is_registered
        else IoUringEnterFlags()

    comptime SQE_FLAGS = IoUringSqeFlags.FIXED_FILE if Self.is_registered
        else IoUringSqeFlags()

    var _fd: UnsafeFd

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_fd: UnsafeFd):
        """Constructs an IoUringFd from an unsafe file descriptor.

        Args:
            unsafe_fd: The unsafe file descriptor.

        Safety:
            The resource pointed to by `unsafe_fd` must be open.
        """
        self._fd = unsafe_fd

    @always_inline("nodebug")
    def unsafe_fd(self) -> UnsafeFd:
        """Extracts an unsafe file descriptor.

        Returns:
            The unsafe file descriptor.
        """
        return self._fd


struct OwnedFd[is_registered: Bool = False](
    RegisterPassable,
    IoUringFileDescriptor,
):
    """An owned io_uring file descriptor that is automatically closed/unregistered
    in its destructor.
    """
    comptime IS_REGISTERED = Self.is_registered
    comptime SETUP_FLAGS = IoUringFd[Self.is_registered].SETUP_FLAGS
    comptime REGISTER_FLAGS = IoUringFd[Self.is_registered].REGISTER_FLAGS
    comptime ENTER_FLAGS = IoUringFd[Self.is_registered].ENTER_FLAGS
    comptime SQE_FLAGS = IoUringFd[Self.is_registered].SQE_FLAGS

    var _fd: UnsafeFd
    """The underlying file descriptor."""

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    @always_inline("nodebug")
    def __init__(out self, *, unsafe_fd: UnsafeFd):
        """Constructs an OwnedFd from an unsafe file descriptor.

        Args:
            unsafe_fd: The unsafe file descriptor.

        Safety:
            The resource pointed to by `unsafe_fd` must be open and suitable for
            assuming ownership. The resource must not require any cleanup other
            than `close/unregister`.
        """
        debug_assert(unsafe_fd > -1, "invalid file descriptor")
        self._fd = unsafe_fd

    @always_inline("nodebug")
    def __deinit__(deinit self):
        """Closes/unregisters the file descriptor."""
        comptime if Self.is_registered:
            var op = IoUringRsrcUpdate()
            op.offset = UInt32(self._fd)
            var arg = op.as_register_arg(
                unsafe_opcode=IoUringRegisterOp.UNREGISTER_RING_FDS
            )
            try:
                var res = io_uring_register(self, arg)
                debug_assert(res == 1, "failed to unregister file descriptor")
            except e:
                # EINVAL (-22) is expected when the ring is already torn
                # down; only fire the diagnostic for unexpected errors.
                debug_assert(
                    String(e) == String(-Int(EINVAL)),
                    "OwnedFd.__deinit__: io_uring_register failed: " + String(e),
                )
        else:
            close_unchecked(unsafe_fd=self._fd)

    # ===------------------------------------------------------------------=== #
    # Trait implementations
    # ===------------------------------------------------------------------=== #

    @always_inline("nodebug")
    def unsafe_fd(self) -> UnsafeFd:
        """Extracts an unsafe file descriptor.

        Returns:
            The unsafe file descriptor.
        """
        return self._fd

    @always_inline("nodebug")
    def io_uring_fd(self) -> IoUringFd[Self.is_registered]:
        return IoUringFd[Self.is_registered](unsafe_fd=self._fd)


# ===----------------------------------------------------------------------=== #
# Enter / Register argument types
# ===----------------------------------------------------------------------=== #


struct EnterArg[size: UInt, flags: IoUringEnterFlags, origin: ImmOrigin](
    TrivialRegisterPassable,
):
    """Argument for `io_uring_enter`.

    Parameters:
        size: The size of the enter argument.
        flags: The bitmask of the `IoUringEnterFlags` values.
        origin: The origin of the enter argument.
    """

    var arg_unsafe_ptr: Pointer[c_void, ImmStaticOrigin]

    @always_inline("nodebug")
    def __init__(
        out self,
        *,
        arg_unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
    ):
        self.arg_unsafe_ptr = arg_unsafe_ptr


comptime NO_ENTER_ARG = EnterArg[0, IoUringEnterFlags(), ImmStaticOrigin](
    arg_unsafe_ptr=null_ptr[c_void, ImmStaticOrigin]()
)


struct IoUringGetEventsArg(Defaultable, ImplicitlyCopyable, Movable):
    var sigmask: UInt64
    var sigmask_sz: UInt32
    var pad: UInt32
    var ts: UInt64

    @always_inline
    def __init__(out self):
        self.sigmask = 0
        self.sigmask_sz = 0
        self.pad = 0
        self.ts = 0


trait AsRegisterArg:
    def as_register_arg[
        origin: MutOrigin
    ](
        ref [origin] self, *, unsafe_opcode: IoUringRegisterOp
    ) -> RegisterArg[origin]:
        ...


struct RegisterArg[origin: MutOrigin](TrivialRegisterPassable):
    var opcode: IoUringRegisterOp
    """The operation code."""
    var arg_unsafe_ptr: Pointer[c_void, ImmStaticOrigin]
    """The pointer to resources for registration/deregistration."""
    var nr_args: UInt32
    """The number of resources for registration/deregistration."""

    @always_inline
    def __init__(
        out self,
        *,
        opcode: IoUringRegisterOp,
        arg_unsafe_ptr: Pointer[c_void, ImmStaticOrigin],
        nr_args: UInt32,
    ):
        self.opcode = opcode
        self.arg_unsafe_ptr = arg_unsafe_ptr
        self.nr_args = nr_args


struct NoRegisterArg:
    comptime ENABLE_RINGS = RegisterArg[MutUntrackedOrigin](
        opcode=IoUringRegisterOp.REGISTER_ENABLE_RINGS,
        arg_unsafe_ptr=null_ptr[c_void, ImmStaticOrigin](),
        nr_args=0,
    )


# ===----------------------------------------------------------------------=== #
# Resource helper structs
# ===----------------------------------------------------------------------=== #


struct IoUringRsrcUpdate(TrivialRegisterPassable, AsRegisterArg, Defaultable):
    var offset: UInt32
    var resv: UInt32
    var data: UInt64

    @always_inline
    def __init__(out self):
        self.offset = 0
        self.resv = 0
        self.data = 0

    @always_inline
    def as_register_arg[
        origin: MutOrigin
    ](
        ref [origin] self, *, unsafe_opcode: IoUringRegisterOp
    ) -> RegisterArg[origin]:
        _aligned_u64[Self]()
        # Bind &self first: inlining Pointer(to=self) into the
        # constructor arg list risks losing the stack address mid-marshal.
        var self_p = Pointer(to=self)
        return RegisterArg[origin](
            opcode=unsafe_opcode,
            arg_unsafe_ptr=Pointer[c_void, ImmStaticOrigin](
                unsafe_from_address=Int(self_p)
            ),
            nr_args=1,
        )


struct IoUringBufReg(AsRegisterArg, Defaultable, ImplicitlyCopyable, Movable):
    var ring_addr: UInt64
    var ring_entries: UInt32
    var bgid: UInt16
    var pad: UInt16
    var resv: DTypeArray[DType.uint64, 3]

    @always_inline
    def __init__(out self):
        self.ring_addr = 0
        self.ring_entries = 0
        self.bgid = 0
        self.pad = 0
        self.resv = DTypeArray[DType.uint64, 3]()

    @always_inline
    def __init__(out self, *, bgid: UInt16):
        self.ring_addr = 0
        self.ring_entries = 0
        self.bgid = bgid
        self.pad = 0
        self.resv = DTypeArray[DType.uint64, 3]()

    @always_inline
    def __init__(
        out self, *, ring_addr: UInt64, ring_entries: UInt32, bgid: UInt16
    ):
        self.ring_addr = ring_addr
        self.ring_entries = ring_entries
        self.bgid = bgid
        self.pad = 0
        self.resv = DTypeArray[DType.uint64, 3]()

    @always_inline
    def as_register_arg[
        origin: MutOrigin
    ](
        ref [origin] self, *, unsafe_opcode: IoUringRegisterOp
    ) -> RegisterArg[origin]:
        _size_eq[Self, 40]()
        _align_eq[Self, 8]()
        # Bind &self first: inlining Pointer(to=self) into the
        # constructor arg list risks losing the stack address mid-marshal.
        var self_p = Pointer(to=self)
        return RegisterArg[origin](
            opcode=unsafe_opcode,
            arg_unsafe_ptr=Pointer[c_void, ImmStaticOrigin](
                unsafe_from_address=Int(self_p)
            ),
            nr_args=1,
        )


# ===----------------------------------------------------------------------=== #
# Syscall wrappers
# ===----------------------------------------------------------------------=== #


@always_inline
def io_uring_setup[
    is_registered: Bool
](sq_entries: UInt32, mut params: IoUringParams) raises -> OwnedFd[
    is_registered
]:
    """Sets up a context for performing asynchronous I/O.
    [Linux]: https://www.man7.org/linux/man-pages/man2/io_uring_setup.2.html.

    Parameters:
        is_registered: Whether the returned file descriptor is registered or not.

    Args:
        sq_entries: The requested number of submission queue entries.
        params: The struct used by the application to pass options to
                the kernel, and by the kernel to convey information about
                the ring buffers.

    Returns:
        The file descriptor which can be used to perform subsequent
        operations on the `io_uring` instance.

    Raises:
        `Errno` if the syscall returned an error.
    """
    params.flags |= OwnedFd[is_registered].SETUP_FLAGS

    # Bind the &params local first: inlining Pointer(to=params) into the
    # syscall arg list can let the stack slot be clobbered during marshaling.
    var params_p = Pointer(to=params)
    var res = syscall[__NR_io_uring_setup, Scalar[DType.int64]](
        sq_entries, params_p
    )
    return OwnedFd[is_registered](
        unsafe_fd=unsafe_decode_result[DType.int32](res)
    )


@always_inline
def io_uring_register[
    Fd: IoUringFileDescriptor
](fd: Fd, arg: RegisterArg) raises -> UInt32:
    """Registers/unregisters files or user buffers for asynchronous I/O.
    [Linux]: https://www.man7.org/linux/man-pages/man2/io_uring_register.2.html.

    Parameters:
        Fd: The type of the file descriptor returned by `io_uring_setup`.

    Args:
        fd: The file descriptor returned by `io_uring_setup`.
        arg: The resources for registration/deregistration.

    Returns:
        Either 0 or a positive value, depending on the operation code used.

    Raises:
        `Errno` if the syscall returned an error.
    """
    var res = syscall[__NR_io_uring_register, Scalar[DType.int64]](
        fd.unsafe_fd(),
        arg.opcode.id | Fd.REGISTER_FLAGS.value,
        arg.arg_unsafe_ptr,
        arg.nr_args,
    )
    return unsafe_decode_result[DType.uint32](res)


@always_inline
def io_uring_enter[
    Fd: IoUringFileDescriptor
](
    fd: Fd,
    *,
    to_submit: UInt32,
    min_complete: UInt32,
    flags: IoUringEnterFlags,
    arg: EnterArg,
) raises -> UInt32:
    """Initiates and/or waits for asynchronous I/O to complete.
    [Linux]: https://man7.org/linux/man-pages/man2/io_uring_enter.2.html.

    Parameters:
        Fd: The type of the file descriptor returned by `io_uring_setup`.

    Args:
        fd: The file descriptor returned by `io_uring_setup`.
        to_submit: The number of I/Os to submit from the submission
                          queue.
        min_complete: The specified number of events to wait for before
                      returning (if `GETEVENTS` flag is set).
        flags: The bitmask of the `IoUringEnterFlags` values.
        arg: The enter argument (wait parameters).

    Returns:
        The number of I/Os successfully consumed. This can be zero
        if `to_submit` was zero or if the submission queue was empty.

    Raises:
        `Errno` if the syscall returned an error. The raise message is the
        negated errno as a string (matching `unsafe_decode_result`'s
        contract), so callers can recover the errno via `Errno(error=...)`.
        EINTR is retried transparently and never surfaces.
    """
    var res: Scalar[DType.int64]
    while True:
        res = syscall[__NR_io_uring_enter, Scalar[DType.int64]](
            fd.unsafe_fd(),
            to_submit,
            min_complete,
            flags | arg.flags | Fd.ENTER_FLAGS,
            arg.arg_unsafe_ptr,
            arg.size,
        )
        if res >= 0:
            break
        # Retry transparently if a signal interrupted the syscall — losing
        # CQEs because SIGCHLD fired is not acceptable in real servers.
        if is_eintr(res):
            continue
        break
    return unsafe_decode_result[DType.uint32](res)
