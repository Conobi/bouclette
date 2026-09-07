"""ReadFileFuture --- async file read via WatchLoop.

`_ReadFileState` holds the per-operation Completion token, the aligned
buffer the kernel writes into, the file offset, and the raw completion
result (bytes read or negative errno). `ReadFileFuture` is the RAII
handle returned to callers.

The buffer is owned by the operation, not by the caller: the read verb
takes the `AlignedBuffer` by value and moves it into this slab-owned
state, right next to the Completion whose address the driver holds.
While the read is in flight nobody but the kernel can reach those
bytes --- the caller no longer has the buffer.  `result()` hands it back.

The state is shared with the WatchLoop that submitted the read (see
`_callback.mojo` for the ownership rules).  Dropping the ReadFileFuture
before the completion arrives is safe and simply gives up the buffer:
the loop frees the state, buffer included, once the read is done or
when the loop itself is destroyed.  Destroying the loop before the
completion arrives is also safe: the loop abandons the buffer first (it
can no longer promise the kernel is finished with it), the future frees
the state on drop, and result() reports the destroyed loop.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.buffer import AlignedBuffer
from boucle.proactor.completion import Completion
from boucle.watch._callback import _FutureCallback, _SlotLink, _dispatch
from boucle.watch.transfer import FileTransferFailed, FileTransferResult


# ===----------------------------------------------------------------------=== #
# _ReadFileState --- internal, slab-owned per-operation state
# ===----------------------------------------------------------------------=== #


struct _ReadFileState(_FutureCallback):
    """Internal state for a single async file read operation.

    Implements _FutureCallback so the generic `_dispatch` can deliver
    completion results into this struct and the WatchLoop registry can
    settle its ownership.

    Fields:
        completion: The per-operation completion token (fn ptr + context
                    ptr) whose address the driver holds.
        buf: The aligned buffer the kernel writes into.  Owned here for
             the whole operation.
        offset: The file offset to read from.
        _result: Raw completion result (bytes read >= 0, or negative errno).
        done: True once the completion callback has fired.
        _owner_dropped: True if the ReadFileFuture was dropped before done;
                        the WatchLoop then frees this state.
        _loop_gone: True if the WatchLoop was destroyed before done;
                    the ReadFileFuture then frees this state.
        _link: The slot this state lives in and the loop's settle queue.
    """

    var completion: Completion
    var buf: AlignedBuffer
    var offset: UInt64
    var _result: Int
    var done: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(out self, var buf: AlignedBuffer, offset: UInt64):
        """Construct a `_ReadFileState` owning the receive buffer.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context once the state is in its slot.

        Args:
            buf: The aligned buffer to read into, moved in for the
                 duration of the operation.
            offset: The file offset to read from.
        """
        self.completion = Completion()
        self.buf = buf^
        self.offset = offset
        self._result = 0
        self.done = False
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source state to move from.
        """
        self.completion = move.completion^
        self.buf = move.buf^
        self.offset = move.offset
        self._result = move._result
        self.done = move.done
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def take_buffer(mut self) -> AlignedBuffer:
        """Move the read buffer out, leaving a minimal placeholder behind.

        Returns:
            The aligned buffer the kernel wrote into.
        """
        var buf = self.buf^
        self.buf = AlignedBuffer(capacity=1)
        return buf^

    def abandon_buffer(mut self):
        """Give up the read buffer instead of freeing it.

        Called when the WatchLoop is destroyed with this read still in
        flight.  The kernel may not be finished with the memory, so
        returning it to the allocator would let someone else be handed
        a buffer the kernel still writes into.  Parking it on the heap
        and never freeing it leaks the allocation on purpose: a bounded
        cost, paid only when a loop is destroyed mid-operation, in
        exchange for never corrupting live memory.
        """
        var parked = unsafe_alloc[AlignedBuffer](1)
        parked.unsafe_write(self.take_buffer())

    def set_result(mut self, result: Int):
        """Store the raw completion result of the read and mark it done.

        Args:
            result: The completion result reported by the backend (bytes
                    read >= 0, or negative errno on failure).
        """
        self._result = result
        self.done = True

    def is_done(self) -> Bool:
        """Return True once the completion callback has fired.

        Returns:
            True if no callback will write this state again.
        """
        return self.done

    def owner_dropped(self) -> Bool:
        """Return True if the ReadFileFuture was dropped before completion.

        Returns:
            True if the WatchLoop must free this state.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        Returns:
            True if the ReadFileFuture is the sole remaining owner.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this read in flight."""
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


# ===----------------------------------------------------------------------=== #
# ReadFileFuture --- RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct ReadFileFuture(Movable):
    """RAII handle for an in-flight async file read operation.

    Points at a slab-owned `_ReadFileState` which in turn owns the
    aligned buffer.  Call `done()` to check completion, then `result()`
    to get the byte count and the buffer back.

    `result()` consumes the future, so there is no second call to guard
    against.  Dropping the future without calling `result()` is safe and
    means giving the buffer up: it is freed with the state once the
    completion has arrived.  Destroying the loop before completion is
    also safe --- `result()` then raises `FileTransferFailed` with
    ``reason == LOOP_GONE``.
    """

    var _state: Pointer[_ReadFileState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_ReadFileState, MutUntrackedOrigin],
    ):
        """Construct a ReadFileFuture wrapping a slab-owned state.

        Args:
            state: Pointer to the slab-owned `_ReadFileState`.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor --- transfers ownership of the state pointer.

        Args:
            move: The source ReadFileFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the loop has already been destroyed, this handle is the last
        reader of the state: its contents are destroyed here --- and with
        them the buffer nobody asked for --- while the slot memory stays
        with the leaked slab.  Otherwise the state is marked as orphaned
        and the loop's slab releases it: at the sweep after the
        completion arrives, or when the loop itself is destroyed.
        """
        if self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
        else:
            self._state[].mark_owner_dropped()

    def result(deinit self) raises FileTransferFailed -> FileTransferResult:
        """Take the byte count and the buffer from a completed file read.

        Consumes the future --- there is nothing left to call twice.  The
        count is the number of bytes at the front of the buffer that the
        kernel wrote (0 means end of file); the buffer's own length is
        unchanged, it is still the window that was submitted.

        Every failure is a `FileTransferFailed`.  A failed read carries
        ``reason == IO``, the errno in ``error``, and the buffer,
        recoverable with `take_buffer()`.  Calling before the completion
        arrived is ``NOT_DONE`` (the loop keeps the buffer and releases it
        when the read finishes); a loop destroyed first is ``LOOP_GONE``
        (its destructor abandoned the buffer).  Neither of those returns a
        buffer.

        Returns:
            The byte count paired with the aligned buffer.

        Raises:
            `FileTransferFailed` with the reason above.
        """
        var state = self._state
        if not state[].done:
            if state[]._loop_gone:
                state.unsafe_deinit_pointee()
                raise FileTransferFailed.loop_gone()
            state[].mark_owner_dropped()
            raise FileTransferFailed.not_done()

        var raw = state[]._result
        var buf = state[].take_buffer()
        if state[]._loop_gone:
            state.unsafe_deinit_pointee()
        else:
            state[].mark_owner_dropped()
        if raw < 0:
            raise FileTransferFailed.io(raw, buf^)
        return FileTransferResult(Int(raw), buf^)

    def done(self) -> Bool:
        """Return True if the file read operation has completed.

        Stays False forever if the loop was destroyed first; `result()`
        then raises with the reason.

        Returns:
            True once the completion callback has fired (success or
            failure).
        """
        return self._state[].done
