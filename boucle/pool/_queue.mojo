"""Cross-thread work queue for the worker pool.

`_WorkQueue` is the single piece of shared state between the loop thread
and every worker thread: workers block in `pop()` waiting for `WorkItem`s,
run them, and hand the outcome back via `push_result()`. The loop thread
later drains finished work with `drain_results()`, woken through the
shared eventfd (`boucle.pool._notify`).

A `pthread_mutex_t` (`boucle.socle.linux.thread._Mutex`) guards the two
ring buffers; a `pthread_cond_t` (`_Condvar`) lets `pop()` block without
spinning. Workers never touch the eventfd under the lock: `push_result()`
unlocks first and notifies after, so a slow write(2) never holds up
another worker posting its own result.

The item count, result count, shutdown flag and active-thread count are
all `Atomic`, not plain scalars, even though every access happens under
`_mutex`. The Mojo compiler's alias analysis sees that an
`external_call` to a pthread function (mutex lock/unlock, condvar
wait/signal) cannot alias a struct field, so it is free to cache a
struct field's value across that call. In a condvar wait loop this
means a worker thread can keep re-reading a stale count it loaded
before calling `condvar.wait()`, even though the producer incremented
it under the same mutex before signalling. `Atomic.load`/`fetch_add`/
`fetch_sub`/`store` compile to real load/store/RMW instructions that
the compiler cannot hoist or cache across an opaque call, which closes
that hole. The mutex is still required for correctness of the
ring-buffer contents and for the condvar's wait/signal protocol; the
atomics only guarantee that the *counters* are never read stale.

`_items` and `_results` are fixed-capacity ring buffers built from raw
`unsafe_alloc`, not `List`. Mojo's `List` is not safe to mutate from a
raw pthread-spawned worker thread even under a mutex — condvar wakeups
get lost and contents corrupt under concurrent load. Keeping every
allocator touch on the main thread (construction, `drain_results()`,
`cancel_pending()`, destruction) and using `unsafe_write`/
`unsafe_take_pointee` for cross-thread handoff avoids the allocator
entirely on worker threads.
"""

from std.atomic import Atomic, Ordering
from std.collections import Optional
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from boucle.handle import OwnedHandle, RawHandle
from boucle.pool._notify import _notify_raw
from boucle.proactor.completion import Completion
from boucle.socle.linux.thread import _Condvar, _Mutex


# Function-pointer type for a unit of blocking work run on a worker thread.
# Signature: (context_ptr) -> result
comptime WorkFn = def (Pointer[NoneType, MutUntrackedOrigin]) thin -> Int32

# Default number of slots in each ring buffer. A worker pool that queues
# more than this many pending items or undelivered results at once is a
# programming error, guarded by `debug_assert` rather than resized.
comptime _DEFAULT_CAPACITY = 256


# ── WorkItem ─────────────────────────────────────────────────────────────


struct WorkItem(Movable):
    """One unit of blocking work submitted to the pool.

    Fields:
        work_fn: The function a worker thread runs off the event loop.
        context: Opaque pointer passed to `work_fn`, owned by the caller.
        completion: The caller's completion token, fired with the result
                    once the loop drains it from the queue.
    """

    var work_fn: WorkFn
    var context: Pointer[NoneType, MutUntrackedOrigin]
    var completion: Pointer[Completion, MutUntrackedOrigin]

    def __init__(
        out self,
        *,
        work_fn: WorkFn,
        context: Pointer[NoneType, MutUntrackedOrigin],
        completion: Pointer[Completion, MutUntrackedOrigin],
    ):
        """Bundle a unit of work with the context and completion it fires.

        Args:
            work_fn: The function a worker thread runs.
            context: Opaque pointer passed to `work_fn`.
            completion: The completion token fired with the result.
        """
        self.work_fn = work_fn
        self.context = context
        self.completion = completion

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.work_fn = move.work_fn
        self.context = move.context
        self.completion = move.completion


# ── _CompletedWork ───────────────────────────────────────────────────────


struct _CompletedWork(Movable):
    """The outcome of one `WorkItem`, ready for the loop to deliver.

    Fields:
        completion: The completion token to fire.
        result: The value `work_fn` returned.
    """

    var completion: Pointer[Completion, MutUntrackedOrigin]
    var result: Int32

    def __init__(
        out self,
        *,
        completion: Pointer[Completion, MutUntrackedOrigin],
        result: Int32,
    ):
        """Pair a finished work item's completion with its result.

        Args:
            completion: The completion token to fire.
            result: The value `work_fn` returned.
        """
        self.completion = completion
        self.result = result

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.completion = move.completion
        self.result = move.result


# ── _WorkQueue ───────────────────────────────────────────────────────────


struct _WorkQueue(Movable):
    """Shared queue of pending work and completed results.

    One `_WorkQueue` is shared by every worker thread and the loop that
    owns them. `push`/`pop` move `WorkItem`s from the loop thread to a
    worker; `push_result`/`drain_results` move `_CompletedWork` back.

    Both queues are fixed-capacity ring buffers, not `List`s: a raw
    pthread-spawned worker thread must never touch Mojo's allocator, and
    `List` is unsafe to mutate cross-thread even under a mutex. Every
    slot is written with `unsafe_write` and taken with
    `unsafe_take_pointee`, so no allocation happens on `push`, `pop` or
    `push_result`. `drain_results()` and `cancel_pending()` build their
    returned `List`s on the calling (loop) thread, where allocation is
    safe.

    Fields:
        _items: Pending-work ring buffer, FIFO.
        _items_head: Index of the oldest pending item.
        _items_count: Number of pending items currently queued. Atomic so
                      a worker's re-read after `condvar.wait()` cannot be
                      served from a stale cached value across the
                      intervening `external_call`.
        _items_cap: Capacity of `_items`.
        _results: Finished-work ring buffer, FIFO.
        _results_head: Index of the oldest finished result.
        _results_count: Number of finished results currently queued.
                        Atomic for the same reason as `_items_count`.
        _results_cap: Capacity of `_results`.
        _mutex: Guards `_items` and `_results`; every counter access
                still happens under it, but the counters are atomic so
                the compiler cannot cache them across a pthread call.
        _condvar: Signalled on `push` and `shutdown`; `pop` waits on it.
        _shutdown: Set once, never cleared. `pop` returns `None` once set
                   and the pending queue is empty. Atomic (0/1) so a
                   worker blocked in the wait loop observes the flag as
                   soon as `shutdown()` sets it.
        _wakeup_fd: The loop's eventfd. Notified after every
                    `push_result`, outside the lock.
        _active_threads: Worker threads that have not yet called
                         `thread_exited`. Atomic for the same reason as
                         the other counters.
    """

    var _items: Pointer[WorkItem, MutUntrackedOrigin]
    var _items_head: Int
    var _items_count: Atomic[DType.int64]
    var _items_cap: Int

    var _results: Pointer[_CompletedWork, MutUntrackedOrigin]
    var _results_head: Int
    var _results_count: Atomic[DType.int64]
    var _results_cap: Int

    var _mutex: _Mutex
    var _condvar: _Condvar
    var _shutdown: Atomic[DType.uint8]
    var _wakeup_fd: OwnedHandle
    var _active_threads: Atomic[DType.int64]

    def __init__(
        out self,
        *,
        wakeup_fd: RawHandle,
        thread_count: Int,
        items_capacity: Int = _DEFAULT_CAPACITY,
        results_capacity: Int = _DEFAULT_CAPACITY,
    ) raises:
        """Create an empty queue shared by `thread_count` workers.

        Args:
            wakeup_fd: The loop's eventfd, notified on every completed item.
            thread_count: Number of worker threads sharing this queue.
            items_capacity: Maximum pending items queued at once.
            results_capacity: Maximum finished results queued at once.

        Raises:
            If `wakeup_fd` is not a valid handle, or the mutex/condvar
            cannot be initialised.
        """
        self._items = unsafe_alloc[WorkItem](items_capacity)
        self._items_head = 0
        self._items_count = Atomic[DType.int64](0)
        self._items_cap = items_capacity

        self._results = unsafe_alloc[_CompletedWork](results_capacity)
        self._results_head = 0
        self._results_count = Atomic[DType.int64](0)
        self._results_cap = results_capacity

        self._mutex = _Mutex()
        self._condvar = _Condvar()
        self._shutdown = Atomic[DType.uint8](0)
        self._wakeup_fd = OwnedHandle(raw=wakeup_fd)
        self._active_threads = Atomic[DType.int64](Int64(thread_count))

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self._items = move._items
        self._items_head = move._items_head
        self._items_count = Atomic[DType.int64](
            move._items_count.load[ordering=Ordering.RELAXED]()
        )
        self._items_cap = move._items_cap

        self._results = move._results
        self._results_head = move._results_head
        self._results_count = Atomic[DType.int64](
            move._results_count.load[ordering=Ordering.RELAXED]()
        )
        self._results_cap = move._results_cap

        self._mutex = move._mutex^
        self._condvar = move._condvar^
        self._shutdown = Atomic[DType.uint8](
            move._shutdown.load[ordering=Ordering.RELAXED]()
        )
        self._wakeup_fd = move._wakeup_fd^
        self._active_threads = Atomic[DType.int64](
            move._active_threads.load[ordering=Ordering.RELAXED]()
        )

    def __deinit__(deinit self):
        """Destroy any queued items/results, then free both ring buffers."""
        while Int(self._items_count.load[ordering=Ordering.RELAXED]()) > 0:
            self._items.unsafe_offset(
                self._items_head
            ).unsafe_deinit_pointee()
            self._items_head = (self._items_head + 1) % self._items_cap
            _ = self._items_count.fetch_sub[ordering=Ordering.RELAXED](1)
        self._items.unsafe_free()

        while (
            Int(self._results_count.load[ordering=Ordering.RELAXED]()) > 0
        ):
            self._results.unsafe_offset(
                self._results_head
            ).unsafe_deinit_pointee()
            self._results_head = (self._results_head + 1) % self._results_cap
            _ = self._results_count.fetch_sub[ordering=Ordering.RELAXED](1)
        self._results.unsafe_free()

    def push(mut self, var item: WorkItem):
        """Submit a work item for a worker thread to run.

        Called from the loop thread. Wakes one blocked worker.

        Args:
            item: The work to run.
        """
        self._mutex.lock()
        var ic = Int(self._items_count.load[ordering=Ordering.RELAXED]())
        debug_assert(ic < self._items_cap, "work queue full")
        var tail = (self._items_head + ic) % self._items_cap
        self._items.unsafe_offset(tail).unsafe_write(item^)
        _ = self._items_count.fetch_add[ordering=Ordering.RELAXED](1)
        self._condvar.signal()
        self._mutex.unlock()

    def pop(mut self) -> Optional[WorkItem]:
        """Block until work is available or the queue is shut down.

        Called from a worker thread.

        Returns:
            The next work item, FIFO, or `None` once `shutdown()` has been
            called and no work remains.
        """
        self._mutex.lock()
        while (
            Int(self._items_count.load[ordering=Ordering.RELAXED]()) == 0
            and self._shutdown.load[ordering=Ordering.RELAXED]() == 0
        ):
            self._condvar.wait(self._mutex)
        if Int(self._items_count.load[ordering=Ordering.RELAXED]()) == 0:
            self._mutex.unlock()
            return None
        var work = self._items.unsafe_offset(
            self._items_head
        ).unsafe_take_pointee()
        self._items_head = (self._items_head + 1) % self._items_cap
        _ = self._items_count.fetch_sub[ordering=Ordering.RELAXED](1)
        self._mutex.unlock()
        return work^

    def push_result(mut self, var result: _CompletedWork):
        """Hand a finished item's outcome back to the loop thread.

        Called from a worker thread. Notifies the loop's eventfd after
        releasing the lock, so a slow write(2) never blocks another
        worker from posting its own result.

        Args:
            result: The completion token and value to deliver.
        """
        self._mutex.lock()
        var rc = Int(self._results_count.load[ordering=Ordering.RELAXED]())
        debug_assert(rc < self._results_cap, "results queue full")
        var tail = (self._results_head + rc) % self._results_cap
        self._results.unsafe_offset(tail).unsafe_write(result^)
        _ = self._results_count.fetch_add[ordering=Ordering.RELAXED](1)
        self._mutex.unlock()
        _notify_raw(self.wakeup_fd_raw_unchecked())

    def drain_results(mut self) -> List[_CompletedWork]:
        """Take every finished result currently queued.

        Called from the loop thread after the eventfd wakes it. The
        returned `List` is built here, on the calling (loop) thread,
        where allocation is safe.

        Returns:
            Every `_CompletedWork` queued since the last drain, FIFO.
            Empty if none arrived.
        """
        self._mutex.lock()
        var out = List[_CompletedWork]()
        while (
            Int(self._results_count.load[ordering=Ordering.RELAXED]()) > 0
        ):
            out.append(
                self._results.unsafe_offset(
                    self._results_head
                ).unsafe_take_pointee()
            )
            self._results_head = (self._results_head + 1) % self._results_cap
            _ = self._results_count.fetch_sub[ordering=Ordering.RELAXED](1)
        self._mutex.unlock()
        return out^

    def shutdown(mut self):
        """Mark the queue shut down and wake every blocked worker.

        Once shut down, `pop()` returns `None` as soon as the pending
        queue drains; it never blocks again.
        """
        self._mutex.lock()
        self._shutdown.store[ordering=Ordering.RELAXED](1)
        self._condvar.broadcast()
        self._mutex.unlock()

    def cancel_pending(mut self) -> List[WorkItem]:
        """Take every work item still waiting for a worker.

        Called during pool teardown, after `shutdown()`, to hand back
        whatever no worker got to. The caller is responsible for firing
        each item's completion with a cancellation result. The returned
        `List` is built here, on the calling (loop) thread, where
        allocation is safe.

        Returns:
            Every `WorkItem` that was queued but not yet popped.
        """
        self._mutex.lock()
        var out = List[WorkItem]()
        while Int(self._items_count.load[ordering=Ordering.RELAXED]()) > 0:
            out.append(
                self._items.unsafe_offset(
                    self._items_head
                ).unsafe_take_pointee()
            )
            self._items_head = (self._items_head + 1) % self._items_cap
            _ = self._items_count.fetch_sub[ordering=Ordering.RELAXED](1)
        self._mutex.unlock()
        return out^

    def thread_exited(mut self) -> Bool:
        """Record that one worker thread has exited its run loop.

        Returns:
            True if this was the last active worker thread, meaning the
            queue's shared state can now be safely freed.
        """
        self._mutex.lock()
        var prev = self._active_threads.fetch_sub[
            ordering=Ordering.RELAXED
        ](1)
        var is_last = Int(prev) == 1
        self._mutex.unlock()
        return is_last

    def wakeup_fd_raw(self) raises -> RawHandle:
        """Return the loop's eventfd, checked.

        Raises:
            If the stored handle is somehow invalid (negative).
        """
        return self._wakeup_fd.raw()

    def wakeup_fd_raw_unchecked(self) -> RawHandle:
        """Return the loop's eventfd without validating it.

        Used from worker threads, which never need `raises` on their hot
        path and trust the loop to keep the handle valid for the queue's
        lifetime.
        """
        return self._wakeup_fd._raw
