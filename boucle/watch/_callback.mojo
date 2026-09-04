"""Internal traits and generic hooks for Future state ownership.

Two type-erased hand-offs meet here. The driver holds each operation's
Completion (function pointer + void* context) and fires it on completion
arrival; the WatchLoop holds a registry entry for every state still in
flight so that it can settle ownership after each tick and when it is
destroyed. Both sides work on `Pointer[NoneType, MutUntrackedOrigin]`
and cast back to the concrete state type through one monomorphised
function each (`_dispatch`, `_sweep`, `_detach`).

Ownership of the heap-allocated state is shared between the Future
handle the caller holds and the WatchLoop that submitted the operation:

- A handle dropped after the state is done frees it (the loop has
  already forgotten the entry).
- A handle dropped before the state is done marks it `owner_dropped`;
  the loop frees it in its post-tick sweep once done, or in its own
  destructor if it never gets there.
- A loop destroyed before the state is done marks it `loop_gone`; the
  handle frees it on drop and reports the loss from result().

The completion callback itself only records the result; it never frees.

Not part of the public API.
"""

from std.memory import Pointer


trait _InFlightState(Movable, Deinitable):
    """Internal trait for heap-allocated operation states tracked by WatchLoop.

    Every state the loop registers, simple or composite, exposes the
    three facts the loop needs to settle ownership: whether the
    operation has finished, whether the Future handle has already been
    dropped, and whether the loop has already been destroyed.
    Deinitable because the loop destroys and frees the state when the
    handle is gone. Not part of the public API.
    """

    def is_done(self) -> Bool:
        """Return True once every completion of the operation has arrived.

        Returns:
            True if the state will never be written by a callback again.
        """
        ...

    def owner_dropped(self) -> Bool:
        """Return True if the Future handle was dropped before completion.

        When True, nobody will read the result and nobody else will free
        the state: the loop must release it once the state is done, or
        when the loop itself is destroyed.

        Returns:
            True if the owning Future is gone; False if it still exists.
        """
        ...

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        When True, no callback can ever fire again and the Future handle
        is the sole owner of the state.

        Returns:
            True if the loop is gone; False while it is alive.
        """
        ...

    def mark_loop_gone(mut self):
        """Record that the WatchLoop has been destroyed with this state in flight."""
        ...


trait _FutureCallback(_InFlightState):
    """Internal trait for simple Future states driven by one completion.

    Implementors receive the completion result via set_result(), which must
    also mark the state done. Not part of the public API.
    """

    def set_result(mut self, result: Int):
        """Store the completion result from a completion and mark the state done.

        Args:
            result: The operation result (negative errno on error,
                    non-negative on success).
        """
        ...


# Function-pointer types stored in a WatchLoop registry entry.
comptime _SweepFn = def (Pointer[NoneType, MutUntrackedOrigin]) thin -> Bool
comptime _DetachFn = def (Pointer[NoneType, MutUntrackedOrigin]) thin -> None


def _dispatch[F: _FutureCallback](
    ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
):
    """Generic completion dispatch to a typed _FutureCallback.

    After monomorphisation this is a plain function pointer compatible with
    CompletionFn — no closure capture, no heap allocation.

    Only records the result. Freeing an orphaned state is the WatchLoop's
    job (see `_sweep`), so the registry never holds a dangling pointer.

    Args:
        ctx: Type-erased pointer to the heap-allocated _FutureCallback
             implementor.
        result: The operation result.
        flags: The operation flags (currently unused by _FutureCallback).
    """
    var state_ptr = ctx.unsafe_bitcast[F]()
    state_ptr[].set_result(result)


def _sweep[F: _InFlightState](ctx: Pointer[NoneType, MutUntrackedOrigin]) -> Bool:
    """Settle a registry entry after a tick; return True if it can be dropped.

    A state that is not done stays registered. A done state leaves the
    registry: if its Future handle was dropped early the loop is the last
    owner and frees it here; otherwise the handle frees it on its own
    drop.

    Args:
        ctx: Type-erased pointer to the heap-allocated state.

    Returns:
        True if the entry must be removed from the registry.
    """
    var state_ptr = ctx.unsafe_bitcast[F]()
    if not state_ptr[].is_done():
        return False
    if state_ptr[].owner_dropped():
        state_ptr.unsafe_deinit_pointee()
        state_ptr.unsafe_free()
    return True


def _detach[F: _InFlightState](ctx: Pointer[NoneType, MutUntrackedOrigin]):
    """Sever a registry entry from a WatchLoop that is being destroyed.

    Called for every entry still registered when the loop dies, after
    the driver has been torn down so no callback can fire concurrently.
    If the Future handle was already dropped the state has no owner left
    and is freed. Otherwise the handle becomes the sole owner: the state
    is marked `loop_gone` so the handle frees it on drop and reports the
    destroyed loop from result().

    Args:
        ctx: Type-erased pointer to the heap-allocated state.
    """
    var state_ptr = ctx.unsafe_bitcast[F]()
    if state_ptr[].owner_dropped():
        state_ptr.unsafe_deinit_pointee()
        state_ptr.unsafe_free()
    else:
        state_ptr[].mark_loop_gone()


struct _InFlightEntry(Copyable, Movable):
    """One WatchLoop registry entry: a type-erased state plus its two hooks.

    Fields:
        state: Type-erased pointer to the heap-allocated operation state.
        sweep: `_sweep[F]` for the state's concrete type.
        detach: `_detach[F]` for the state's concrete type.
    """

    var state: Pointer[NoneType, MutUntrackedOrigin]
    var sweep: _SweepFn
    var detach: _DetachFn

    def __init__[F: _InFlightState](
        out self, state: Pointer[F, MutUntrackedOrigin]
    ):
        """Register a typed state, monomorphising its hooks.

        Parameters:
            F: The concrete state type.

        Args:
            state: Pointer to the heap-allocated state to track.
        """
        self.state = state.unsafe_bitcast[NoneType]()
        self.sweep = _sweep[F]
        self.detach = _detach[F]

    def __init__(out self, *, copy: Self):
        """Copy constructor."""
        self.state = copy.state
        self.sweep = copy.sweep
        self.detach = copy.detach

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.state = move.state
        self.sweep = move.sweep
        self.detach = move.detach
