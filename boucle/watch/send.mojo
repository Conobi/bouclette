"""SendFuture — async send via WatchLoop.

_SendFutureState holds the per-operation Completion token and the raw
completion result (bytes written or negative errno). SendFuture is the
RAII handle returned to callers.

The state is shared with the WatchLoop that submitted the send (see
`_callback.mojo` for the ownership rules). Dropping the SendFuture
before the completion arrives is safe: the loop frees the state once it
is done or when the loop itself is destroyed. Destroying the loop before
the completion arrives is also safe: the future frees the state on drop
and result() reports the destroyed loop.

Warning: The buffer passed to WatchLoop.send() is NOT owned by the
FutureState. The caller must ensure the buffer remains valid until
run() completes. Dropping the SendFuture early does not change this —
the kernel may still read from the buffer until the completion arrives.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.proactor.completion import Completion
from boucle.watch._callback import _FutureCallback, _dispatch


# ===----------------------------------------------------------------------=== #
# _SendFutureState — internal, heap-allocated per-operation state
# ===----------------------------------------------------------------------=== #


struct _SendFutureState(_FutureCallback):
    """Internal state for a single async send operation.

    Implements _FutureCallback so the generic _dispatch can deliver
    completion results into this struct and the WatchLoop registry can
    settle its ownership.

    Fields:
        completion: The io_uring completion token (fn ptr + context ptr).
        _result: Raw completion result (bytes written >= 0, or negative
                 errno).
        done: True once the completion callback has fired.
        consumed: True once result() has been called.
        _owner_dropped: True if the SendFuture was dropped before done;
                        the WatchLoop then frees this state.
        _loop_gone: True if the WatchLoop was destroyed before done;
                    the SendFuture then frees this state.
    """

    var completion: Completion
    var _result: Int
    var done: Bool
    var consumed: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool

    def __init__(out self):
        """Construct a _SendFutureState.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context after heap allocation.
        """
        self.completion = Completion()
        self._result = 0
        self.done = False
        self.consumed = False
        self._owner_dropped = False
        self._loop_gone = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source state to move from.
        """
        self.completion = move.completion^
        self._result = move._result
        self.done = move.done
        self.consumed = move.consumed
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone

    def set_result(mut self, result: Int):
        """Store the raw completion result from io_uring send and mark done.

        Args:
            result: The io_uring completion result (bytes written >= 0, or
                    negative errno on failure).
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
        """Return True if the SendFuture was dropped before completion.

        Returns:
            True if the WatchLoop must free this state.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        Returns:
            True if the SendFuture is the sole remaining owner.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this send in flight."""
        self._loop_gone = True


# ===----------------------------------------------------------------------=== #
# SendFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct SendFuture(Movable):
    """RAII handle for an in-flight async send operation.

    Owns a heap-allocated _SendFutureState. Call done() to check
    completion, then result() to extract the byte count.

    The buffer is NOT owned by this future — the caller must keep it
    alive until run() completes, even if this future is dropped first.
    Dropping the future before completion is otherwise safe, as is
    destroying the loop before completion (result() then raises).
    """

    var _state: Pointer[_SendFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_SendFutureState, MutUntrackedOrigin],
    ):
        """Construct a SendFuture wrapping a heap-allocated state.

        Args:
            state: Pointer to the heap-allocated _SendFutureState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source SendFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the completion has been delivered, or the loop has already
        been destroyed, this handle is the last owner and frees the
        state. Otherwise the loop still tracks the state, so it is
        marked as orphaned and the loop frees it — after the completion
        arrives during run(), or when the loop itself is destroyed.
        """
        if self._state[].done or self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
            self._state.unsafe_free()
        else:
            self._state[]._owner_dropped = True

    def result(mut self) raises -> Int:
        """Extract the number of bytes sent.

        Consumes the result — a second call raises. Raises on negative
        completion result (kernel error).

        Returns:
            The number of bytes sent.

        Raises:
            If the result was already consumed, the loop was destroyed
            before the operation completed, the operation has not
            completed, or the send syscall returned an error.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            if self._state[]._loop_gone:
                raise "loop destroyed before completion"
            raise "operation not complete"
        self._state[].consumed = True
        if self._state[]._result < 0:
            raise String(
                "send failed: errno ",
                Int(-self._state[]._result),
            )
        return Int(self._state[]._result)

    def done(self) -> Bool:
        """Return True if the send operation has completed.

        Stays False forever if the loop was destroyed first; result()
        then raises with the reason.

        Returns:
            True once the completion callback has fired (success or
            failure).
        """
        return self._state[].done
