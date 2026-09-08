"""SendMsgFuture — async sendmsg via WatchLoop.

The RAII handle for a one-shot `WatchLoop.send_msg` (and its `send_to`
wrapper). It points at a slab-owned `_MessageState` (`_message.mojo`)
holding the `Message` the kernel reads: the payload, the destination
and the control records appended since the last `clear_control` or
receive (`Message.set_ecn`, `Message.set_gso_segment_size`,
`Message.append_control`). `result()` hands the message back unchanged
inside a `MessageResult`, or raises `MessageFailed` carrying it.

Ownership follows `_callback.mojo`: dropping the future before the
completion arrives gives the message up and the loop releases it once
the sendmsg is done; a loop destroyed first abandons the message and the
future reports `LOOP_GONE`.
"""

from std.memory import Pointer

from boucle.net.message import MessageResult
from boucle.watch._message import _MessageState
from boucle.watch.transfer import MessageFailed


struct SendMsgFuture(Movable):
    """RAII handle for an in-flight async sendmsg operation.

    Call done() to check completion, then result() to get the byte
    count and the message back. result() consumes the future. Dropping
    the future without calling result() is safe and gives the message
    up.
    """

    var _state: Pointer[_MessageState, MutUntrackedOrigin]

    def __init__(out self, state: Pointer[_MessageState, MutUntrackedOrigin]):
        """Construct a SendMsgFuture wrapping a slab-owned state.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the loop has already been destroyed this handle is the last
        reader of the state: its contents are destroyed here while the
        slot memory stays with the leaked slab. Otherwise the state is
        marked as orphaned and the loop's slab releases it at the sweep
        after the completion arrives, or when the loop is destroyed.
        """
        if self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
        else:
            self._state[].mark_owner_dropped()

    def result(deinit self) raises MessageFailed -> MessageResult:
        """Take the outcome of a completed sendmsg.

        Consumes the future. The result's `count` is how many payload
        bytes went out; a datagram is sent whole or not at all, so for
        UDP it equals the payload length. The message comes back as it
        was submitted; its flags are 0.

        Every failure is a `MessageFailed`. A failed sendmsg carries
        `reason == IO`, the errno in `error`, and the message,
        recoverable with `take_message()`. Calling before the completion
        arrived is `NOT_DONE` (the loop keeps the message); a loop
        destroyed first is `LOOP_GONE` (the message was abandoned).
        Neither of those returns a message.

        Returns:
            The byte count and message.

        Raises:
            MessageFailed with the reason above.
        """
        var state = self._state
        if not state[].done:
            if state[]._loop_gone:
                state.unsafe_deinit_pointee()
                raise MessageFailed.loop_gone()
            state[].mark_owner_dropped()
            raise MessageFailed.not_done()

        var raw = state[]._result
        var flags = state[].flags()
        var msg = state[].take_message()
        if state[]._loop_gone:
            state.unsafe_deinit_pointee()
        else:
            state[].mark_owner_dropped()
        if raw < 0:
            raise MessageFailed.io(raw, msg^)
        return MessageResult(Int(raw), msg^, flags)

    def done(self) -> Bool:
        """Return True if the sendmsg has completed.

        Stays False forever if the loop was destroyed first; result()
        then raises LOOP_GONE.
        """
        return self._state[].done
