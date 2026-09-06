"""Owned messages for sendmsg/recvmsg and the decoders around them.

`Message` is what `WatchLoop.send_msg` and `WatchLoop.recv_msg` take by
value and hand back: one payload buffer, a peer address slot, and a
control byte area. `ControlMessages` walks the cmsghdr records in that
area; `MessageResult` is what a completed message operation returns.
`DeliveryHeader` decodes the 16-byte prefix a multishot recvmsg
delivery prepends to a provided buffer, shared by the io_uring and
epoll completion drivers.

Control records follow the 64-bit Linux layout: a 16-byte `cmsghdr`
(8-byte `cmsg_len`, `int` level, `int` type) followed by the data, with
every record padded to an 8-byte boundary (`CMSG_ALIGN`). `cmsg_len`
counts the header and the data, not the padding.
"""

from std.memory import Pointer
from std.sys.info import size_of

from boucle.error import IOError
from boucle.net.addr import (
    SocketAddrStor,
    SocketAddrStorAny,
    SocketAddrStorV4,
    SocketAddrStorV6,
    SocketAddrV4,
    SocketAddrV6,
)
from boucle.net.options import AddrFamily
from boucle.socle.platform import (
    cmsghdr,
    sockaddr_in,
    sockaddr_in6,
    EAFNOSUPPORT,
    EINVAL,
    IP_TOS,
    IPV6_TCLASS,
    MSG_CTRUNC,
    MSG_TRUNC,
    SOL_IP,
    SOL_IPV6,
)


# cmsg records are aligned to `size_t`: 8 bytes on every 64-bit Linux arch.
comptime _CMSG_ALIGN_TO = 8


@always_inline
def _cmsg_align(n: Int) -> Int:
    """Round a byte count up to the cmsg record alignment.

    Args:
        n: A record length (header plus data).

    Returns:
        `n` rounded up to a multiple of 8.
    """
    return (n + _CMSG_ALIGN_TO - 1) & ~(_CMSG_ALIGN_TO - 1)


# ===----------------------------------------------------------------------=== #
# ControlMessage / ControlMessages
# ===----------------------------------------------------------------------=== #


struct ControlMessage[origin: ImmOrigin](ImplicitlyCopyable, Movable):
    """One control record: its level, its type, and a view of its data.

    Parameters:
        origin: The origin of the control area the record was read from.

    Fields:
        level: The `cmsg_level` (SOL_IP, SOL_IPV6, SOL_SOCKET, ...).
        type: The `cmsg_type` within that level (IP_TOS, IPV6_TCLASS, ...).
    """

    var level: Int32
    var type: Int32
    var _data: Span[UInt8, Self.origin]

    def __init__(
        out self, level: Int32, type: Int32, data: Span[UInt8, Self.origin]
    ):
        """Construct a record view.

        Args:
            level: The record's protocol level.
            type: The record's type within the level.
            data: The record's data bytes, header and padding excluded.
        """
        self.level = level
        self.type = type
        self._data = data

    def data(self) -> Span[UInt8, Self.origin]:
        """Return the record's data bytes.

        Returns:
            `cmsg_len - 16` bytes starting right after the header.
        """
        return self._data


struct ControlMessages[origin: ImmOrigin](ImplicitlyCopyable, Movable):
    """Iterator over the cmsghdr records in a control byte area.

    Records are 8-byte aligned (CMSG_ALIGN on 64-bit Linux). A record
    whose `cmsg_len` is smaller than the header, or that runs past the
    end of the area, ends iteration: nothing after it can be trusted.
    A `__next__` past the end returns an empty record and leaves the
    walker exhausted; it never reads beyond the span.

    Parameters:
        origin: The origin of the control area being walked.
    """

    var _bytes: Span[UInt8, Self.origin]
    var _offset: Int

    def __init__(out self, bytes: Span[UInt8, Self.origin]):
        """Start a walk at the first record.

        Args:
            bytes: The control area, exactly `msg_controllen` bytes long.
        """
        self._bytes = bytes
        self._offset = 0

    def __iter__(self) -> Self:
        """Return a copy of this cursor, positioned where this one is.

        A walk resumes from the current record, not from the first: to
        restart, build a new `ControlMessages` over the same bytes.

        Returns:
            A copy positioned wherever this one is.
        """
        return self

    def __has_next__(self) -> Bool:
        """Return True while a whole, well-formed record remains.

        Returns:
            False at the end of the area, on a record shorter than its
            header, or on a record that overruns the area.
        """
        var hdr = size_of[cmsghdr]()
        if self._offset + hdr > len(self._bytes):
            return False
        var cmsg_len = self._read_len(self._offset)
        if cmsg_len < hdr:
            return False
        # `cmsg_len` comes straight off the wire and can be near Int.MAX;
        # `self._offset + cmsg_len` can wrap negative and slip past a
        # `<=` check for any record after the first. Compare the other way
        # around instead: `len(self._bytes) - self._offset` is bounded by
        # the buffer length and, thanks to the check above, never negative,
        # so this subtraction cannot wrap.
        return cmsg_len <= len(self._bytes) - self._offset

    def __next__(mut self) -> ControlMessage[Self.origin]:
        """Return the record at the cursor and advance past its padding.

        Past the end, or on a malformed record, nothing is read: the
        cursor moves to the end of the span and an empty record (level
        0, type 0, no data) comes back, on this call and every later one.

        Returns:
            The current record, or an empty one once exhausted.
        """
        if not self.__has_next__():
            self._offset = len(self._bytes)
            return ControlMessage[Self.origin](0, 0, self._bytes[0:0])
        var hdr = size_of[cmsghdr]()
        var cmsg_len = self._read_len(self._offset)
        var level = self._read_i32(self._offset + 8)
        var type = self._read_i32(self._offset + 12)
        var data = self._bytes[self._offset + hdr : self._offset + cmsg_len]
        # `cmsg_len` passed `__has_next__`'s check, so it is at most
        # `len(self._bytes) - self._offset`; rounding it up to the next
        # 8-byte boundary stays within the buffer size plus at most 7 and
        # cannot overflow.
        self._offset += _cmsg_align(cmsg_len)
        return ControlMessage[Self.origin](level, type, data)

    def _read_len(self, at: Int) -> Int:
        """Read the 8-byte `cmsg_len` at `at`.

        Args:
            at: Byte offset of a record header.

        Returns:
            The record length, header included.
        """
        var p = (
            self._bytes.unsafe_ptr().unsafe_offset(at).unsafe_bitcast[UInt64]()
        )
        return Int(p.unsafe_load[alignment=1]())

    def _read_i32(self, at: Int) -> Int32:
        """Read an unaligned Int32 at `at`.

        Args:
            at: Byte offset of the field.

        Returns:
            The field value.
        """
        var p = (
            self._bytes.unsafe_ptr().unsafe_offset(at).unsafe_bitcast[Int32]()
        )
        return p.unsafe_load[alignment=1]()

    def ecn(self) -> Optional[UInt8]:
        """Return the ECN codepoint carried by the first TOS record.

        Reads the low two bits of an `IP_TOS` record (one data byte) or
        an `IPV6_TCLASS` record (a four-byte little-endian int),
        whichever comes first. A dual-stack receiver with `set_recv_tos`
        gets one or the other depending on the peer's family.

        Returns:
            The codepoint (0 to 3), or None when no such record exists.
        """
        for cm in self:
            if (
                cm.level == Int32(SOL_IP)
                and cm.type == Int32(IP_TOS)
                and len(cm.data()) >= 1
            ):
                return cm.data()[0] & 0x03
            if (
                cm.level == Int32(SOL_IPV6)
                and cm.type == Int32(IPV6_TCLASS)
                and len(cm.data()) >= 4
            ):
                return cm.data()[0] & 0x03
        return None


# ===----------------------------------------------------------------------=== #
# Message
# ===----------------------------------------------------------------------=== #


struct Message(Movable):
    """An owned message for sendmsg/recvmsg.

    One payload buffer, an optional peer address slot, and a control
    byte area. The loop moves a Message into its per-operation state at
    submission and hands it back from `MessageResult.take_message` or
    from the error raised when the operation fails, so the caller never
    shares the bytes with the kernel.

    For a send: the payload's whole length is offered, the peer (if set)
    is the destination, and the control record written by `set_ecn`
    goes out with the datagram. For a receive: the payload's length is
    the window, the peer slot receives the sender's address, and up to
    `control_capacity` bytes of control records are collected.

    The control area keeps two lengths. The bytes the kernel wrote on
    the last receive are only ever read back (`MessageResult.control`);
    a send never offers them, so a peer cannot pick the TOS, the
    pktinfo or anything else of a reply by what it sent. The bytes
    `set_ecn` wrote are the only ones a send offers. Both start at the
    front of the area, so at most one of the two is non-zero at a time.

    Fields:
        _payload: The data buffer, moved in.
        _peer: The peer address slot; `addr_len() == 0` when unset.
        _control: The control area, allocated at full `control_capacity`
                  bytes up front; writers fill bytes in place.
        _control_received: How many bytes of `_control` the kernel wrote
                           on the last receive. Never offered to a send.
        _control_appended: How many bytes of `_control` hold the record
                           `set_ecn` wrote. The only bytes a send offers.
    """

    var _payload: List[UInt8]
    var _peer: SocketAddrStorAny
    var _control: List[UInt8]
    var _control_received: Int
    var _control_appended: Int

    def __init__(
        out self, var payload: List[UInt8], *, control_capacity: Int = 0
    ):
        """Construct a message around a payload buffer.

        Args:
            payload: The bytes to send, or the window to receive into.
            control_capacity: Bytes reserved for control records. Each
                              TOS/TCLASS record takes 24; a receiver that
                              wants ECN needs at least that much. A
                              negative value reserves nothing.
        """
        self._payload = payload^
        self._peer = SocketAddrStorAny()
        self._control = List[UInt8](length=max(control_capacity, 0), fill=0)
        self._control_received = 0
        self._control_appended = 0

    def set_peer[Addr: SocketAddrStor](mut self, ref addr: Addr):
        """Set the destination for a send.

        Parameters:
            Addr: The address type, SocketAddrV4 or SocketAddrV6.

        Args:
            addr: The peer address.
        """
        self._peer = SocketAddrStorAny(addr.addr_stor())

    def peer_family(self) -> AddrFamily:
        """Return the family of the peer slot.

        Returns:
            UNSPEC when no peer was set and none was written by a
            receive; otherwise INET or INET6.
        """
        return self._peer.family()

    def set_ecn(
        mut self, mark: UInt8, family: Optional[AddrFamily] = None
    ) raises IOError:
        """Write the control record carrying an ECN codepoint.

        Writes an `IP_TOS` record (one byte) or an `IPV6_TCLASS` record
        (a four-byte int) at the start of the control area, replacing
        any record an earlier call wrote and discarding whatever the
        kernel wrote on the last receive: received records never go out
        with a send. The family is derived from the peer when one is set
        and `family` is None; otherwise `family` is required.

        A peer that is an IPv4-mapped IPv6 address (::ffff:a.b.c.d)
        derives AF_INET, not AF_INET6: the kernel's IPv6 UDP send path
        hands a mapped destination to the IPv4 sender before it parses
        IPv6 control messages, and the IPv4 sender ignores every level
        other than SOL_IP, so only an IP_TOS record reaches the wire for
        such peers (net/ipv6/udp.c udpv6_sendmsg, net/ipv4/ip_sockglue.c
        ip_cmsg_send).

        A per-datagram `IP_TOS`/`IPV6_TCLASS` record replaces the whole
        TOS byte for that datagram, so any DSCP bits set on the socket
        are zeroed for it, not merged with `mark`.

        Args:
            mark: The codepoint; only the low two bits are used.
            family: Which record to write when the peer does not decide
                    it, or to override the peer.

        Raises:
            IOError(EINVAL) when neither a peer nor a family is
            available, or when `control_capacity` cannot hold the record.
        """
        var fam: AddrFamily
        if family:
            fam = family.value()
        else:
            fam = self.peer_family()
            if fam == AddrFamily.INET6:
                var stor = SocketAddrStorV6()
                stor.addr = self._peer.addr
                if stor.to_v6().is_ipv4_mapped():
                    fam = AddrFamily.INET
        var level: Int32
        var type: Int32
        var data_len: Int
        if fam == AddrFamily.INET:
            level = Int32(SOL_IP)
            type = Int32(IP_TOS)
            data_len = 1
        elif fam == AddrFamily.INET6:
            level = Int32(SOL_IPV6)
            type = Int32(IPV6_TCLASS)
            data_len = 4
        else:
            raise IOError(positive_errno=EINVAL)
        var hdr = size_of[cmsghdr]()
        var record = _cmsg_align(hdr + data_len)
        if record > len(self._control):
            raise IOError(positive_errno=EINVAL)
        var p = self._control.unsafe_ptr()
        for i in range(record):
            p[unsafe_offset=i] = UInt8(0)
        p.unsafe_bitcast[UInt64]().unsafe_store[alignment=1](
            UInt64(hdr + data_len)
        )
        p.unsafe_offset(8).unsafe_bitcast[Int32]().unsafe_store[alignment=1](
            level
        )
        p.unsafe_offset(12).unsafe_bitcast[Int32]().unsafe_store[alignment=1](
            type
        )
        if data_len == 1:
            p[unsafe_offset=hdr] = mark & 0x03
        else:
            p.unsafe_offset(hdr).unsafe_bitcast[Int32]().unsafe_store[
                alignment=1
            ](Int32(mark & 0x03))
        self._control_appended = record
        self._control_received = 0

    def clear_control(mut self):
        """Drop every control record: received and written alike.

        The area keeps its capacity; a send offers no control bytes and
        `control()` walks nothing until `set_ecn` writes again.
        """
        self._control_received = 0
        self._control_appended = 0

    def payload(ref self) -> ref[self._payload] List[UInt8]:
        """Borrow the payload buffer.

        Returns:
            The list handed to the constructor.
        """
        return self._payload

    def take_payload(deinit self) -> List[UInt8]:
        """Take the payload buffer back, consuming the message.

        Returns:
            The list handed to the constructor, same storage.
        """
        return self._payload^

    def control_capacity(self) -> Int:
        """Return how many control bytes this message can hold.

        Returns:
            The `control_capacity` given at construction.
        """
        return len(self._control)

    def control(ref self) -> ControlMessages[origin_of(self._control)]:
        """Walk the control records currently held.

        Whatever occupies the area: the records the kernel wrote on the
        last receive, or the record `set_ecn` wrote since (received or
        appended, never both). The two share the front of the area, so
        only one of them is present at a time.

        Returns:
            An iterator over the records.
        """
        return ControlMessages(
            Span(self._control)[
                : max(self._control_received, self._control_appended)
            ]
        )

    def _set_control_received(mut self, len: Int):
        """Record how many control bytes the kernel wrote on a receive.

        Clamped to the capacity: the kernel truncates and flags
        MSG_CTRUNC rather than overrunning, but the length it reports
        is not trusted past the area. The kernel overwrote the front of
        the area, so any record `set_ecn` wrote before is gone too.

        Args:
            len: The `msg_controllen` written back by the kernel.
        """
        var cap = self.control_capacity()
        self._control_received = len if len < cap else cap
        self._control_appended = 0


# ===----------------------------------------------------------------------=== #
# MessageResult
# ===----------------------------------------------------------------------=== #


struct MessageResult(Movable):
    """The outcome of one completed send_msg or recv_msg.

    Mojo 1.0 cannot destructure a tuple holding a non-copyable value, so
    the byte count, the message and the kernel's `msg_flags` travel in
    one named struct, the same shape as `TransferResult`.

    Fields:
        count: How many payload bytes moved. For a receive this is how
               many bytes at the front of the payload are valid; the
               payload's length is unchanged. For a send it is how many
               bytes went out. Under MSG_TRUNC the kernel reports the
               full datagram length here, which can exceed the payload;
               `transferred()` clamps to the payload's own length and
               never does.
    """

    var count: Int
    var _msg: Message
    var _flags: Int32

    def __init__(out self, count: Int, var msg: Message, flags: Int32):
        """Pair a byte count with the message the operation used.

        Args:
            count: The number of bytes transferred.
            msg: The message, handed back from the loop.
            flags: The `msg_flags` the kernel wrote (MSG_TRUNC,
                   MSG_CTRUNC); 0 for a send.
        """
        self.count = count
        self._msg = msg^
        self._flags = flags

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source result.
        """
        self.count = move.count
        self._msg = move._msg^
        self._flags = move._flags

    def peer_family(self) -> AddrFamily:
        """Return the family of the peer address.

        Returns:
            UNSPEC when the slot holds no address (a receive on a
            connected stream socket writes none; a send keeps the
            destination it was given), otherwise INET or INET6.
        """
        return self._msg.peer_family()

    def peer_v4(self) raises IOError -> SocketAddrV4:
        """Decode the peer as an IPv4 address.

        The name the kernel wrote must cover a whole `sockaddr_in`: a
        matching family byte alone is not enough, since the rest of the
        slot would be whatever a previous peer left there.

        Returns:
            The peer address and port.

        Raises:
            IOError(EAFNOSUPPORT) when the peer is not AF_INET or the
            written name is shorter than a `sockaddr_in`.
        """
        if (
            Int(self._msg._peer.addr_len()) < size_of[sockaddr_in]()
            or self.peer_family() != AddrFamily.INET
        ):
            raise IOError(positive_errno=EAFNOSUPPORT)
        var stor = SocketAddrStorV4()
        stor.addr = Pointer(to=self._msg._peer.addr).unsafe_bitcast[
            sockaddr_in
        ]()[]
        return stor.to_v4()

    def peer_v6(self) raises IOError -> SocketAddrV6:
        """Decode the peer as an IPv6 address.

        A dual-stack socket reports IPv4 peers as mapped addresses; see
        `SocketAddrV6.is_ipv4_mapped`. The name the kernel wrote must
        cover a whole `sockaddr_in6`, as for `peer_v4`.

        Returns:
            The peer address, port and scope id.

        Raises:
            IOError(EAFNOSUPPORT) when the peer is not AF_INET6 or the
            written name is shorter than a `sockaddr_in6`.
        """
        if (
            Int(self._msg._peer.addr_len()) < size_of[sockaddr_in6]()
            or self.peer_family() != AddrFamily.INET6
        ):
            raise IOError(positive_errno=EAFNOSUPPORT)
        var stor = SocketAddrStorV6()
        stor.addr = self._msg._peer.addr
        return stor.to_v6()

    def control(ref self) -> ControlMessages[origin_of(self._msg._control)]:
        """Walk the control records the kernel wrote.

        Only the bytes written by the receive are walked; for a send
        result there are none.

        Returns:
            An iterator over `msg_controllen` bytes of records.
        """
        return ControlMessages(
            Span(self._msg._control)[: self._msg._control_received]
        )

    def truncated(self) -> Bool:
        """Return True when the datagram did not fit the payload window.

        Returns:
            True if `msg_flags` carries MSG_TRUNC.
        """
        return (Int(self._flags) & MSG_TRUNC) != 0

    def control_truncated(self) -> Bool:
        """Return True when control records did not fit the control area.

        Returns:
            True if `msg_flags` carries MSG_CTRUNC.
        """
        return (Int(self._flags) & MSG_CTRUNC) != 0

    def transferred(ref self) -> Span[UInt8, origin_of(self._msg._payload)]:
        """View the payload bytes that actually moved.

        Clamped to the payload's length: under MSG_TRUNC `count` is the
        full datagram size, which can be larger than the payload the
        caller offered as a receive window.

        Returns:
            The first `count` bytes of the payload, or all of it when
            `count` exceeds the payload's length.
        """
        return Span(self._msg._payload)[: min(self.count, len(self._msg._payload))]

    def take_message(deinit self) -> Message:
        """Take the message back, consuming this result.

        The records the kernel wrote on the receive are dropped on the
        way out: a message reused for a reply starts with no control
        bytes to offer, so nothing the peer sent is replayed to it.

        Returns:
            The message the operation used, payload storage unchanged.
        """
        var msg = self._msg^
        msg._control_received = 0
        return msg^


# ===----------------------------------------------------------------------=== #
# DeliveryHeader — the 16-byte prefix of one multishot recvmsg delivery
# ===----------------------------------------------------------------------=== #

# Layout of io_uring's `struct io_uring_recvmsg_out`:
#   __u32 namelen; __u32 controllen; __u32 payloadlen; __u32 flags;
# The epoll completion driver writes the same four fields so one decoder
# serves both backends.
comptime DELIVERY_HEADER_LEN = 16
comptime _DELIVERY_NAMELEN_OFFSET = 0
comptime _DELIVERY_CONTROLLEN_OFFSET = 4
comptime _DELIVERY_PAYLOADLEN_OFFSET = 8
comptime _DELIVERY_FLAGS_OFFSET = 12


def _verify_delivery_header_layout():
    """Compile-time check that the header is four packed UInt32 fields."""
    comptime assert size_of[UInt32]() == 4, "UInt32 size mismatch"
    comptime assert DELIVERY_HEADER_LEN == 4 * size_of[UInt32](), (
        "delivery header must be four UInt32"
    )
    comptime assert _DELIVERY_CONTROLLEN_OFFSET == size_of[UInt32]()
    comptime assert _DELIVERY_PAYLOADLEN_OFFSET == 2 * size_of[UInt32]()
    comptime assert _DELIVERY_FLAGS_OFFSET == 3 * size_of[UInt32]()


comptime _DELIVERY_LAYOUT_VERIFIED: None = _verify_delivery_header_layout()


def _store_u32(base: Pointer[UInt8, MutUntrackedOrigin], offset: Int, value: UInt32):
    """Store `value` little-endian, one byte at a time, at `base + offset`.

    Byte stores carry no alignment requirement, so a buffer of any size
    (pools allow any size >= 64) can start a header.

    Args:
        base: Start of the buffer.
        offset: Byte offset of the field.
        value: The value to store.
    """
    for i in range(4):
        base[unsafe_offset=offset + i] = UInt8(
            (value >> UInt32(8 * i)) & UInt32(0xFF)
        )


def write_delivery_header(
    base: Pointer[UInt8, MutUntrackedOrigin],
    *,
    namelen: UInt32,
    controllen: UInt32,
    payloadlen: UInt32,
    flags: UInt32,
):
    """Write a delivery header at the start of a provided buffer.

    Used by the epoll completion driver to mirror what the kernel writes
    for an io_uring multishot recvmsg. `base` must point at a buffer of
    at least `DELIVERY_HEADER_LEN` bytes.

    Args:
        base: Start of the provided buffer.
        namelen: Length of the peer address the kernel wrote.
        controllen: Length of the control data the kernel wrote.
        payloadlen: Length of the datagram payload.
        flags: The recvmsg `msg_flags` (MSG_TRUNC, MSG_CTRUNC).
    """
    _store_u32(base, _DELIVERY_NAMELEN_OFFSET, namelen)
    _store_u32(base, _DELIVERY_CONTROLLEN_OFFSET, controllen)
    _store_u32(base, _DELIVERY_PAYLOADLEN_OFFSET, payloadlen)
    _store_u32(base, _DELIVERY_FLAGS_OFFSET, flags)


struct DeliveryHeader[origin: Origin](Copyable, Movable):
    """Decoder for the 16-byte header a multishot recvmsg delivery
    prepends to a provided buffer. The layout is io_uring's
    `io_uring_recvmsg_out`; the epoll driver writes the same layout so one
    decoder serves both backends.

    Header: four little-endian UInt32 at offsets 0, 4, 8, 12: namelen,
    controllen, payloadlen, flags. namelen and controllen are the lengths
    the kernel actually wrote and may exceed the capacities; a value above
    capacity means that region was truncated. Regions follow with no
    alignment padding, at offsets computed from the CAPACITIES the
    operation was submitted with, not from the written lengths:
        name    at 16
        control at 16 + name_capacity
        payload at 16 + name_capacity + control_capacity
    matching liburing's io_uring_recvmsg_name / _cmsg_firsthdr / _payload.
    name() and control() return min(written, capacity) bytes; payload()
    returns payloadlen bytes, or the remaining buffer if payloadlen exceeds
    it (flags then carry MSG_TRUNC). Capacities whose offsets fall beyond
    the buffer clamp to empty regions rather than reading past its end.

    Parameters:
        origin: Origin of the buffer the header views.
    """

    var _buf: Span[UInt8, Self.origin]
    var _name_capacity: Int
    var _control_capacity: Int

    def __init__(
        out self,
        buf: Span[UInt8, Self.origin],
        name_capacity: Int,
        control_capacity: Int,
    ):
        """View a buffer already known to hold a header.

        Prefer `parse`, which checks the length. This constructor is for
        callers that guarantee `len(buf) >= DELIVERY_HEADER_LEN`, such as
        a `Datagram` over a pool buffer of at least 64 bytes. A shorter
        buffer is not undefined behaviour either: every field reads as
        zero and every region is empty.

        Args:
            buf: The provided buffer, header first.
            name_capacity: `msg_namelen` the operation was submitted with.
            control_capacity: `msg_controllen` the operation was submitted with.
        """
        self._buf = buf
        self._name_capacity = name_capacity
        self._control_capacity = control_capacity

    @staticmethod
    def parse(
        buf: Span[UInt8, Self.origin],
        *,
        name_capacity: Int,
        control_capacity: Int,
    ) raises IOError -> Self:
        """Validate the buffer length and view it as a delivery.

        Args:
            buf: The provided buffer, header first.
            name_capacity: `msg_namelen` the operation was submitted with.
            control_capacity: `msg_controllen` the operation was submitted with.

        Returns:
            A header view over `buf`.

        Raises:
            IOError(EINVAL) if `buf` is shorter than 16 bytes.
        """
        if len(buf) < DELIVERY_HEADER_LEN:
            raise IOError(positive_errno=EINVAL)
        return Self(buf, name_capacity, control_capacity)

    def _read_u32(self, offset: Int) -> UInt32:
        """Read the little-endian UInt32 at `offset`, 0 past the buffer.

        A buffer too short to hold the field (an empty span from a
        lease whose pool no longer addresses a buffer) reads as zero, so
        every accessor degrades to an empty region, UNSPEC and no flags
        instead of indexing past the end.

        Args:
            offset: One of the four field offsets.

        Returns:
            The field value, or 0 when the field lies past the buffer.
        """
        if offset + 4 > len(self._buf):
            return 0
        return (
            UInt32(self._buf[offset])
            | (UInt32(self._buf[offset + 1]) << 8)
            | (UInt32(self._buf[offset + 2]) << 16)
            | (UInt32(self._buf[offset + 3]) << 24)
        )

    def _region(self, start: Int, length: Int) -> Span[UInt8, Self.origin]:
        """Return `length` bytes from `start`, clamped to the buffer at
        both ends: a negative or out-of-range `start` clamps to the
        buffer's bounds before `length` is applied.

        Args:
            start: First byte of the region.
            length: Requested length.

        Returns:
            The clamped sub-span (possibly empty).
        """
        var lo = max(min(start, len(self._buf)), 0)
        var hi = min(lo + max(length, 0), len(self._buf))
        return self._buf[lo:hi]

    def namelen(self) -> UInt32:
        """Return the peer address length the kernel wrote."""
        return self._read_u32(_DELIVERY_NAMELEN_OFFSET)

    def controllen(self) -> UInt32:
        """Return the control data length the kernel wrote."""
        return self._read_u32(_DELIVERY_CONTROLLEN_OFFSET)

    def payloadlen(self) -> UInt32:
        """Return the payload length the kernel reported."""
        return self._read_u32(_DELIVERY_PAYLOADLEN_OFFSET)

    def flags(self) -> UInt32:
        """Return the recvmsg msg_flags: MSG_TRUNC, MSG_CTRUNC."""
        return self._read_u32(_DELIVERY_FLAGS_OFFSET)

    def name(ref self) -> Span[UInt8, Self.origin]:
        """Return the peer address bytes: min(namelen, name_capacity) of them."""
        var n = min(Int(self.namelen()), self._name_capacity)
        return self._region(DELIVERY_HEADER_LEN, n)

    def control(ref self) -> ControlMessages[Self.origin]:
        """Return a walker over min(controllen, control_capacity) control bytes."""
        var n = min(Int(self.controllen()), self._control_capacity)
        return ControlMessages(
            self._region(DELIVERY_HEADER_LEN + self._name_capacity, n)
        )

    def payload(ref self) -> Span[UInt8, Self.origin]:
        """Return the payload: payloadlen bytes, or what remains of the buffer."""
        return self._region(
            DELIVERY_HEADER_LEN + self._name_capacity + self._control_capacity,
            Int(self.payloadlen()),
        )
