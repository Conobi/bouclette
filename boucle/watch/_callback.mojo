"""Internal traits and generic hooks for Future state ownership.

The driver holds each operation's Completion (function pointer + void*
context) and fires it on completion arrival; `_dispatch` casts the
context back to the concrete state type and records the result. The
WatchLoop keeps every state in a typed slab (`_slab.mojo`) that doubles
as the registry, and settles ownership through the `_InFlightState`
trait after each tick and when it is destroyed.

Ownership of the slab-owned state is shared between the Future handle
the caller holds and the WatchLoop that submitted the operation:

- A handle never frees a slot. Dropping it, or consuming it through
  result(), marks the state `owner_dropped`; the slab releases the slot
  at its next sweep once the state is done, or in the loop's destructor
  if it never gets there.
- A loop destroyed before the handle is dropped marks the state
  `loop_gone`; the handle then reports the loss from result(), destroys
  the state's contents on drop, and the slab leaves its chunks
  allocated so that read is always valid.

Nothing scans the slabs. Every state carries a `_SlotLink` naming its
slot; of the two events that make a slot reclaimable — the completion
arriving and the handle letting go — the second one pushes the key
onto the loop's settle queue, and the post-tick sweep releases exactly
the slots queued since the last one.

The completion callback itself only records the result; it never frees.

Memory the kernel reads or writes — the recv/send buffers — is a special
case at loop destruction: the loop asks every unfinished state to
`abandon_buffer()` first, because tearing the driver down does not prove
the kernel has let go of those bytes. An abandoned buffer is leaked on
purpose rather than handed back to the allocator.

Not part of the public API.
"""

from std.memory import Pointer

from boucle.socle.ptr import null_ptr


struct _SlotLink(Copyable, ImplicitlyCopyable, Movable):
    """Where a state lives, and whom to tell when that slot may be settled.

    A slot becomes reclaimable when its completion has arrived *and* its
    handle has let go. Whichever of the two happens second pushes the
    slot's key onto the loop's settle queue, so every slot is queued
    exactly once. The completion also decrements the slab's live count,
    which is how `in_flight_count` stays exact without a scan.
    """

    var key: Int
    var queue: Pointer[List[Int], MutUntrackedOrigin]
    var live: Pointer[Int, MutUntrackedOrigin]

    def __init__(out self):
        """Construct an unbound link; both events are no-ops on it."""
        self.key = -1
        self.queue = null_ptr[List[Int], MutUntrackedOrigin]()
        self.live = null_ptr[Int, MutUntrackedOrigin]()

    def __init__(
        out self,
        key: Int,
        queue: Pointer[List[Int], MutUntrackedOrigin],
        live: Pointer[Int, MutUntrackedOrigin],
    ):
        """Construct a link to a slot.

        Args:
            key: The slot key the loop's sweep decodes.
            queue: The loop's settle queue.
            live: The slab's live counter.
        """
        self.key = key
        self.queue = queue
        self.live = live

    def completed(self, owner_dropped: Bool):
        """Record the completion; queue the slot if the handle is gone.

        Args:
            owner_dropped: Whether the handle had already let go.
        """
        if self.key < 0:
            return
        self.live[] -= 1
        if owner_dropped:
            self.queue[].append(self.key)

    def dropped(self, done: Bool):
        """Record the handle letting go; queue the slot if it is done.

        Args:
            done: Whether the completion had already arrived.
        """
        if self.key >= 0 and done:
            self.queue[].append(self.key)

    def rearmed(self):
        """Count the state live again after a re-arm.

        A stream that ended on an error called `completed(False)` and
        stopped counting; resubmitting the operation makes it live once
        more without touching the settle queue.
        """
        if self.key >= 0:
            self.live[] += 1


# Low bits of a slot key that carry the slab kind; the rest is the index.
comptime _KIND_BITS = 4


trait _InFlightState(Deinitable, Movable):
    """Internal trait for slab-owned operation states tracked by WatchLoop.

    Every state the loop registers, simple or composite, exposes the
    three facts the loop needs to settle ownership: whether the
    operation has finished, whether the Future handle has already been
    dropped, and whether the loop has already been destroyed.
    Deinitable because the slab destroys the state in place when the
    handle is gone. Not part of the public API.
    """

    def is_done(self) -> Bool:
        """Return True once every completion of the operation has arrived.
        """
        ...

    def owner_dropped(self) -> Bool:
        """Return True if the Future handle was dropped before completion.

        When True, nobody will read the result and nobody else will free
        the state: the loop must release it once the state is done, or
        when the loop itself is destroyed.
        """
        ...

    def loop_gone(self) -> Bool:
        """Return True if the WatchLoop was destroyed before completion.

        When True, no callback can ever fire again and the Future handle
        is the sole owner of the state.
        """
        ...

    def mark_loop_gone(mut self):
        """Record that the WatchLoop has been destroyed with this state in flight.
        """
        ...

    def bind(mut self, link: _SlotLink):
        """Record which slot holds this state and the queue to notify.

        Called by the slab right after the state is moved into its
        slot, before the operation is submitted.
        """
        ...

    def notify_done(self):
        """Tell the slot link that the completion has arrived.

        Called once, right after the state marks itself done.
        """
        ...

    def mark_owner_dropped(mut self):
        """Record that the Future handle let go, and queue the slot.

        Called by the handle on drop and when result() consumes it.
        Never called once the loop is gone: the queue it would push to
        no longer exists.
        """
        ...

    def abandon_buffer(mut self):
        """Give up any memory the kernel may still be reading or writing.

        Called on every unfinished state when the WatchLoop is destroyed,
        before the driver is torn down. Tearing the driver down does not
        prove the kernel has stopped touching the buffers of requests it
        is still cancelling, so a state holding such memory leaks it
        deliberately rather than returning it to the allocator.

        States that hold no kernel-visible buffer keep this default: the
        timespec and sockaddr the other operations pass are copied by the
        kernel at submission, so there is nothing to abandon.
        """
        pass


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


def _dispatch[
    F: _FutureCallback
](ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32):
    """Generic completion dispatch to a typed _FutureCallback.

    After monomorphisation this is a plain function pointer compatible with
    CompletionFn — no closure capture, no heap allocation.

    Only records the result and queues the slot for the next sweep.
    Releasing an orphaned state is the slab's job, so no pointer the
    loop holds ever dangles.

    Args:
        ctx: Type-erased pointer to the slab-owned _FutureCallback
             implementor.
        result: The operation result.
        flags: The operation flags (currently unused by _FutureCallback).
    """
    var state_ptr = ctx.unsafe_bitcast[F]()
    state_ptr[].set_result(result)
    state_ptr[].notify_done()
