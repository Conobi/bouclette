"""FsyncFuture --- async fsync via WatchLoop.

`_FsyncState` holds the per-operation Completion token and the raw
completion result (0 on success or negative errno).  `FsyncFuture` is
the RAII handle returned to callers.

No buffer is involved: fsync flushes already-written data to stable
storage and has no kernel-visible memory to abandon.

The state is shared with the WatchLoop that submitted the fsync (see
`_callback.mojo` for the ownership rules).  Dropping the FsyncFuture
before the completion arrives is safe: the loop frees the state once
the fsync is done or when the loop itself is destroyed.  Destroying
the loop before the completion arrives is also safe: the future frees
the state on drop and result() reports the destroyed loop.
"""

from std.memory import Pointer

from boucle.error import IOError
from boucle.proactor.completion import Completion
from boucle.socle.platform import ECANCELED, EINVAL
from boucle.watch._callback import _FutureCallback, _SlotLink, _dispatch


# ===----------------------------------------------------------------------=== #
# _FsyncState --- internal, slab-owned per-operation state
# ===----------------------------------------------------------------------=== #


struct _FsyncState(_FutureCallback):
    """Internal state for a single async fsync operation.

    Implements _FutureCallback so the generic `_dispatch` can deliver
    completion results into this struct and the WatchLoop registry can
    settle its ownership.
    """

    var completion: Completion
    var _result: Int
    var done: Bool
    var _owner_dropped: Bool
    var _loop_gone: Bool
    var _link: _SlotLink

    def __init__(out self):
        """Construct a `_FsyncState`.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context once the state is in its slot.
        """
        self.completion = Completion()
        self._result = 0
        self.done = False
        self._owner_dropped = False
        self._loop_gone = False
        self._link = _SlotLink()

    def __init__(out self, *, deinit move: Self):
        self.completion = move.completion^
        self._result = move._result
        self.done = move.done
        self._owner_dropped = move._owner_dropped
        self._loop_gone = move._loop_gone
        self._link = move._link

    def set_result(mut self, result: Int):
        """Store the raw completion result of the fsync and mark it done.
        """
        self._result = result
        self.done = True

    def is_done(self) -> Bool:
        """Return True once the completion callback has fired.
        """
        return self.done

    def owner_dropped(self) -> Bool:
        """Return True if the FsyncFuture was dropped before completion.
        """
        return self._owner_dropped

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.
        """
        return self._loop_gone

    def mark_loop_gone(mut self):
        """Record that the WatchLoop was destroyed with this fsync in flight."""
        self._loop_gone = True

    def bind(mut self, link: _SlotLink):
        """Record the slot this state lives in and the queue to notify.
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
# FsyncFuture --- RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct FsyncFuture(Movable):
    """RAII handle for an in-flight async fsync operation.

    Points at a slab-owned `_FsyncState`.  Call `done()` to check
    completion, then `result()` to verify success.  Dropping the future
    before completion is safe, as is destroying the loop before
    completion (`result()` then raises `IOError`).
    """

    var _state: Pointer[_FsyncState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_FsyncState, MutUntrackedOrigin],
    ):
        """Construct a FsyncFuture wrapping a slab-owned state.

        Args:
            state: Pointer to the slab-owned `_FsyncState`.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        self._state = move._state

    def __deinit__(deinit self):
        """Release the state, or hand it over to the WatchLoop.

        If the loop has already been destroyed, this handle is the last
        reader of the state and destroys its contents here; the slot
        memory stays with the leaked slab.  Otherwise the state is
        marked as orphaned and the loop's slab releases it --- at the
        sweep after the completion arrives, or when the loop itself is
        destroyed.
        """
        if self._state[]._loop_gone:
            self._state.unsafe_deinit_pointee()
        else:
            self._state[].mark_owner_dropped()

    def result(deinit self) raises IOError:
        """Verify that the fsync completed successfully.

        Consumes the future.  Returns nothing on success; raises
        `IOError` on any failure.

        Raises:
            `IOError` when the fsync failed, the loop was destroyed
            before completion, or the operation has not yet completed.
        """
        var state = self._state
        if not state[].done:
            if state[]._loop_gone:
                state.unsafe_deinit_pointee()
                raise IOError(positive_errno=ECANCELED)
            state[].mark_owner_dropped()
            raise IOError(positive_errno=EINVAL)

        var raw = state[]._result
        if state[]._loop_gone:
            state.unsafe_deinit_pointee()
        else:
            state[].mark_owner_dropped()
        if raw < 0:
            raise IOError.from_errno(raw)

    def done(self) -> Bool:
        """Return True if the fsync operation has completed.

        Stays False forever if the loop was destroyed first; `result()`
        then raises.

        Returns:
            True once the completion callback has fired (success or
            failure).
        """
        return self._state[].done
