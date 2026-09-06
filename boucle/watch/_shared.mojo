"""Loop-wide state that slab-resident operation states reach through one pointer.

A pool state returns buffers to the driver when a lease drops; a stream
state asks the driver to re-arm or cancel; both must know whether the
driver still exists, because loop destruction tears it down before it
settles the slabs. Their completion callbacks also fire completions the
loop must account for differently from one-shot futures. None of that
fits in a `_SlotLink`, and a pointer to the `WatchLoop` itself would make
`pool.mojo` and `stream.mojo` import `loop.mojo` in a cycle, so the loop
boxes this struct on the heap and hands every pool and stream state its
address.

Not part of the public API.
"""

from std.memory import Pointer

from boucle.drivers import _WatchDriver
from boucle.socle.ptr import null_ptr


struct _LoopShared(Movable):
    """What every pool and stream state shares with its loop.

    Fields:
        driver: The loop's driver. Re-pointed by the loop's move
                constructor; only read while `driver_alive`.
        driver_alive: False from the moment the loop's destructor starts
                      tearing the driver down. Every driver call made by
                      a state checks it first.
        deferred: The loop's deferred-submission queue of slot keys;
                  a state pushes its key to request a re-arm or a cancel.
        stream_completions: Completions fired this tick by stream
                            callbacks that `step()` reports (deliveries
                            queued for a live stream, and every
                            terminal, including the one that ends an
                            owner-dropped stream, which no handle sees).
                            They were never counted in `_pending`, so
                            the loop must not subtract them.
        internal_completions: Completions fired this tick that no handle
                              can observe: internal cancel operations
                              and deliveries recycled after the stream's
                              handle dropped. Not pending, and not
                              reported by `step()` either.
    """

    var driver: Pointer[_WatchDriver, MutUntrackedOrigin]
    var driver_alive: Bool
    var deferred: Pointer[List[Int], MutUntrackedOrigin]
    var stream_completions: Int
    var internal_completions: Int

    def __init__(out self, deferred: Pointer[List[Int], MutUntrackedOrigin]):
        """Create the shared box with a null driver and zero tally.

        Args:
            deferred: The loop's deferred queue; stable for the loop's life.
        """
        self.driver = null_ptr[_WatchDriver, MutUntrackedOrigin]()
        self.driver_alive = True
        self.deferred = deferred
        self.stream_completions = 0
        self.internal_completions = 0

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source box to move from.
        """
        self.driver = move.driver
        self.driver_alive = move.driver_alive
        self.deferred = move.deferred
        self.stream_completions = move.stream_completions
        self.internal_completions = move.internal_completions

    def reset_tally(mut self):
        """Zero both per-tick counters before a tick starts."""
        self.stream_completions = 0
        self.internal_completions = 0
