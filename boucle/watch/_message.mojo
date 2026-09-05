"""_MessageState — slab-owned state shared by send_msg and recv_msg.

One struct serves both directions: the driver's `sendmsg` and `recvmsg`
take the same msghdr, and the only differences are which fields of the
`Message` are offered to the kernel (`wire`) and which are written back
afterwards (`set_result`). The `_receiving` flag decides.

The state holds the `Message` (moved in), the `msghdr`, and a one-entry
inline iovec array. The msghdr's pointers are filled in by `wire()` once
the state sits in its slab slot: slab chunks never move, and the
`Message`'s list storage does not move once the `Message` is in the
slot, so every address the kernel sees stays valid for the life of the
operation. The name slot is the `Message`'s `SocketAddrStorAny`, written
through `addr_unsafe_mut_ptr()`.

Ownership follows `_callback.mojo`: the callback only records the
result; the handle never frees; the slab settles the slot after the
second of {completion arrived, handle let go}.

Not part of the public API.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.sys.info import size_of

from boucle.net.message import Message
from boucle.proactor.completion import Completion
from boucle.socle.platform import iovec, msghdr, sockaddr_in6, socklen_t
from boucle.watch._callback import _FutureCallback, _SlotLink


struct _MessageState(_FutureCallback):
    """Internal state for a single async sendmsg or recvmsg operation.

    Fields:
        completion: The per-operation completion token whose address the
                    driver holds.
        msg: The message, owned here for the whole operation.
        _hdr: The msghdr the driver is pointed at.
        _iov: The single iovec `_hdr.msg_iov` points at.
        _receiving: True for recvmsg (offer the name slot and the whole
                    control area; record what the kernel wrote), False
                    for sendmsg (offer the peer and records if set).
        _result: Raw completion result (bytes >= 0, or negative errno).
        done: True once the completion callback has fired.
        _owner_dropped: True if the future was dropped before done.
        _loop_gone: True if the WatchLoop was destroyed before done.
        _link: The slot this state lives in and the loop's settle queue.
    """

    var completion: Completion
    var msg: Message
    var _hdr: msghdr
    var _iov: InlineArray[iovec, 1]
    var _receiving: Bool
    var _result: Int
    var done: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(out self, var msg: Message, *, receiving: Bool):
        """Construct a state owning the message.

        The msghdr is left empty; call `wire()` once the state is in its
        slot, then wire the completion.

        Args:
            msg: The message, moved in for the duration of the operation.
            receiving: True for recvmsg, False for sendmsg.
        """
        self.completion = Completion()
        self.msg = msg^
        self._hdr = msghdr()
        self._iov = InlineArray[iovec, 1](fill=iovec())
        self._receiving = receiving
        self._result = 0
        self.done = False
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        The msghdr pointers are not rebased: `wire()` runs after the
        move into the slot, never before.

        Args:
            move: The source state.
        """
        self.completion = move.completion^
        self.msg = move.msg^
        self._hdr = move._hdr
        self._iov = move._iov^
        self._receiving = move._receiving
        self._result = move._result
        self.done = move.done
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def wire(mut self):
        """Point the msghdr and iovec at this slot's own fields.

        Must run after the state is in its slab slot and before the
        operation is submitted. For a receive the whole name slot and
        the whole control area are offered; for a send only a set peer
        and appended control records are. The payload window may be
        empty (`iov_len` 0) for a zero-length send or a receive with no
        bytes requested.
        """
        self._iov[0].iov_base = UInt64(Int(self.msg._payload.unsafe_ptr()))
        self._iov[0].iov_len = UInt64(len(self.msg._payload))
        self._hdr = msghdr()
        self._hdr.msg_iov = UInt64(Int(Pointer(to=self._iov)))
        self._hdr.msg_iovlen = 1
        var name_ptr = self.msg._peer.addr_unsafe_mut_ptr()
        if self._receiving:
            self._hdr.msg_name = UInt64(Int(name_ptr))
            self._hdr.msg_namelen = UInt32(size_of[sockaddr_in6]())
            if self.msg.control_capacity() > 0:
                self._hdr.msg_control = UInt64(
                    Int(self.msg._control.unsafe_ptr())
                )
                self._hdr.msg_controllen = UInt64(self.msg.control_capacity())
        else:
            if self.msg._peer.addr_len() > 0:
                self._hdr.msg_name = UInt64(Int(name_ptr))
                self._hdr.msg_namelen = UInt32(self.msg._peer.addr_len())
            if self.msg._control_len > 0:
                self._hdr.msg_control = UInt64(
                    Int(self.msg._control.unsafe_ptr())
                )
                self._hdr.msg_controllen = UInt64(self.msg._control_len)

    def msghdr_ptr(self) -> Pointer[NoneType, MutUntrackedOrigin]:
        """Return the opaque msghdr pointer the driver takes.

        Returns:
            The address of `_hdr`, valid for the life of the slot.
        """
        return Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self._hdr))
        )

    def flags(self) -> Int32:
        """Return the `msg_flags` the kernel wrote back.

        Returns:
            MSG_TRUNC / MSG_CTRUNC bits after a receive; 0 otherwise.
        """
        return self._hdr.msg_flags

    def take_message(mut self) -> Message:
        """Move the message out, leaving an empty one behind.

        Returns:
            The message the operation used.
        """
        var msg = self.msg^
        self.msg = Message(List[UInt8]())
        return msg^

    def abandon_buffer(mut self):
        """Give up the message instead of freeing it.

        Called when the WatchLoop is destroyed with this operation still
        in flight. Parking the whole message on the heap protects its
        payload and control-area storage: the kernel may still be
        writing into those buffers, so freeing them here would hand the
        allocator memory it still touches. It does not protect the name
        slot or the msghdr — both stay behind in this state's slab slot,
        so the kernel keeps writing the peer address and `msg_flags`
        into slot memory (now owned by the fresh, empty message left in
        `self.msg`) until the operation truly completes. Keeping that
        slot's chunk allocated for as long as the kernel might still
        write into it is the loop's responsibility: see
        `WatchLoop.__deinit__`, which marks the message slabs leaked
        when any message state is abandoned not-done.
        """
        var parked = unsafe_alloc[Message](1)
        parked.unsafe_write(self.take_message())

    def set_result(mut self, result: Int):
        """Store the completion result and mark the state done.

        After a successful receive the peer length and control length
        follow what the kernel wrote into the msghdr.

        Args:
            result: The completion result (bytes >= 0, or negative errno).
        """
        debug_assert(not self.done, "completion delivered twice")
        self._result = result
        self.done = True
        if self._receiving and result >= 0:
            self.msg._peer.set_len(socklen_t(self._hdr.msg_namelen))
            self.msg._set_control_len(Int(self._hdr.msg_controllen))

    def is_done(self) -> Bool:
        """Return True once the completion callback has fired.

        Returns:
            True if no callback will write this state again.
        """
        return self.done

    def owner_dropped(self) -> Bool:
        """Return True if the future was dropped before completion.

        Returns:
            True if the WatchLoop must free this state.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        Returns:
            True if the future is the sole remaining owner.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this operation in flight."""
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Record the slot this state lives in and the queue to notify.

        Args:
            link: The slot key and the loop's settle queue.
        """
        self._link = link

    def notify_done(self):
        """Tell the slot link the completion has arrived."""
        self._link.completed(self._owner_dropped)

    def mark_owner_dropped(mut self):
        """Record that the handle let go, and queue the slot if done."""
        self._owner_dropped = True
        self._link.dropped(self.done)
