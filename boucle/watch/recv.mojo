"""RecvFuture — async recv via WatchLoop.

_RecvFutureState holds the per-operation Completion token, the buffer the
kernel writes into, and the raw completion result (bytes read or negative
errno). RecvFuture is the RAII handle returned to callers.

The buffer is owned by the operation, not by the caller: `recv` takes the
`List[UInt8]` by value and moves it into this heap-allocated state, right
next to the Completion whose address the driver holds. While the recv is
in flight nobody but the kernel can reach those bytes — the caller no
longer has the list, so it can neither read it, write it, nor free it.
`result()` hands it back.

The state is shared with the WatchLoop that submitted the recv (see
`_callback.mojo` for the ownership rules). Dropping the RecvFuture before
the completion arrives is safe and simply gives up the buffer: the loop
frees the state, buffer included, once the recv is done or when the loop
itself is destroyed. Destroying the loop before the completion arrives is
also safe: the loop abandons the buffer first (it can no longer promise
the kernel is finished with it), the future frees the state on drop, and
result() reports the destroyed loop.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.error import IOError
from boucle.proactor.completion import Completion
from boucle.watch._callback import _FutureCallback, _dispatch
from boucle.watch.transfer import TransferResult


# ===----------------------------------------------------------------------=== #
# _RecvFutureState — internal, heap-allocated per-operation state
# ===----------------------------------------------------------------------=== #


struct _RecvFutureState(_FutureCallback):
    """Internal state for a single async recv operation.

    Implements _FutureCallback so the generic _dispatch can deliver
    completion results into this struct and the WatchLoop registry can
    settle its ownership.

    Fields:
        completion: The per-operation completion token (fn ptr + context
                    ptr) whose address the driver holds.
        buf: The buffer the kernel writes into. Owned here for the whole
             operation; its length is the readable window and never
             changes.
        _result: Raw completion result (bytes read >= 0, or negative errno).
        done: True once the completion callback has fired.
        _owner_dropped: True if the RecvFuture was dropped before done;
                        the WatchLoop then frees this state.
        _loop_gone: True if the WatchLoop was destroyed before done;
                    the RecvFuture then frees this state.
    """

    var completion: Completion
    var buf: List[UInt8]
    var _result: Int
    var done: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool

    def __init__(out self, var buf: List[UInt8]):
        """Construct a _RecvFutureState owning the receive buffer.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context after heap allocation.

        Args:
            buf: The buffer to receive into, moved in for the duration
                 of the operation.
        """
        self.completion = Completion()
        self.buf = buf^
        self._result = 0
        self.done = False
        self._owner_dropped = False
        self._loop_gone = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source state to move from.
        """
        self.completion = move.completion^
        self.buf = move.buf^
        self._result = move._result
        self.done = move.done
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone

    def take_buffer(mut self) -> List[UInt8]:
        """Move the receive buffer out, leaving an empty list behind.

        Returns:
            The buffer the kernel wrote into.
        """
        var buf = self.buf^
        self.buf = List[UInt8]()
        return buf^

    def abandon_buffer(mut self):
        """Give up the receive buffer instead of freeing it.

        Called when the WatchLoop is destroyed with this recv still in
        flight. The kernel may not be finished with the memory, so
        returning it to the allocator would let someone else be handed
        a buffer the kernel still writes into. Parking it on the heap
        and never freeing it leaks the allocation on purpose: a bounded
        cost, paid only when a loop is destroyed mid-operation, in
        exchange for never corrupting live memory.
        """
        var parked = unsafe_alloc[List[UInt8]](1)
        parked.unsafe_write(self.take_buffer())

    def set_result(mut self, result: Int):
        """Store the raw completion result of the recv and mark it done.

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
        """Return True if the RecvFuture was dropped before completion.

        Returns:
            True if the WatchLoop must free this state.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        Returns:
            True if the RecvFuture is the sole remaining owner.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this recv in flight."""
        self._loop_gone = True


# ===----------------------------------------------------------------------=== #
# RecvFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct RecvFuture(Movable):
    """RAII handle for an in-flight async recv operation.

    Owns a heap-allocated _RecvFutureState which in turn owns the receive
    buffer. Call done() to check completion, then result() to get the
    byte count and the buffer back.

    result() consumes the future, so there is no second call to guard
    against. Dropping the future without calling result() is safe and
    means giving the buffer up: it is freed with the state once the
    completion has arrived. Destroying the loop before completion is
    also safe — result() then raises.
    """

    var _state: Pointer[_RecvFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_RecvFutureState, MutUntrackedOrigin],
    ):
        """Construct a RecvFuture wrapping a heap-allocated state.

        Args:
            state: Pointer to the heap-allocated _RecvFutureState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source RecvFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the completion has been delivered, or the loop has already
        been destroyed, this handle is the last owner and frees the
        state — and with it the buffer nobody asked for. Otherwise the
        loop still tracks the state, so it is marked as orphaned and the
        loop frees it: after the completion arrives during run(), or
        when the loop itself is destroyed.
        """
        if self._state[].done or self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
            self._state.unsafe_free()
        else:
            self._state[]._owner_dropped = True

    def result(deinit self) raises -> TransferResult:
        """Take the byte count and the buffer from a completed recv.

        Consumes the future — there is nothing left to call twice. The
        count is the number of bytes at the front of the buffer that the
        kernel wrote (0 means end of file); the buffer's own length is
        unchanged, it is still the window that was submitted.

        Two shapes of failure come out of here. A failed recv raises an
        `IOError` carrying the errno, the same type every boucle I/O call
        raises. Misusing the handle raises a plain message instead — no
        syscall failed, so there is no errno to report. The buffer is not
        handed back on either path: raising leaves nothing to return it
        in, so it is freed with the state.

        Returns:
            The byte count paired with the buffer.

        Raises:
            IOError if the recv syscall failed. A plain message if the
            loop was destroyed before the operation completed, or the
            operation has not completed.
        """
        var state = self._state
        if not state[].done:
            if state[]._loop_gone:
                state.unsafe_deinit_pointee()
                state.unsafe_free()
                raise "loop destroyed before completion"
            state[]._owner_dropped = True
            raise "operation not complete"

        var raw = state[]._result
        var buf = state[].take_buffer()
        state.unsafe_deinit_pointee()
        state.unsafe_free()
        if raw < 0:
            raise IOError.from_errno(Int(raw))
        return TransferResult(Int(raw), buf^)

    def done(self) -> Bool:
        """Return True if the recv operation has completed.

        Stays False forever if the loop was destroyed first; result()
        then raises with the reason.

        Returns:
            True once the completion callback has fired (success or
            failure).
        """
        return self._state[].done
