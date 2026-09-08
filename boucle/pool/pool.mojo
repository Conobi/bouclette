"""WorkerPool: dispatches blocking work to OS threads.

`_worker_entry` runs on each worker thread: it pops `WorkItem`s off the
shared `_WorkQueue`, runs them, and pushes the result back for the loop
to drain and deliver through the caller's `Completion`.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from boucle.handle import RawHandle
from boucle.pool._notify import create_eventfd, drain_eventfd
from boucle.pool._queue import WorkItem, _CompletedWork, _WorkQueue
from boucle.socle.linux.thread import _Thread
from boucle.socle.ptr import null_ptr


def _worker_entry(
    arg: Pointer[NoneType, MutUntrackedOrigin],
) -> Pointer[NoneType, MutUntrackedOrigin]:
    """Pop→execute→push-result loop; the last worker to exit frees the queue."""
    var q = arg.unsafe_bitcast[_WorkQueue]()
    while True:
        var item = q[].pop()
        if not item.__bool__():
            break
        var work = item.take()
        var result = work.work_fn(work.context)
        q[].push_result(
            _CompletedWork(completion=work.completion, result=result)
        )
    var is_last = q[].thread_exited()
    if is_last:
        q.unsafe_deinit_pointee()
        q.unsafe_free()
    return null_ptr[NoneType, MutUntrackedOrigin]()


struct WorkerPool(Movable):
    """Dispatches blocking work to a fixed-size pool of OS threads.

    `submit()` enqueues a `WorkItem`; a worker thread runs it and pushes
    the outcome back. The owning loop calls `drain()` — typically after
    `wakeup_fd()` reports readable — to collect finished results and fire
    their completions.

    Teardown never blocks: `__deinit__` cancels unstarted work, wakes
    every worker and detaches all threads rather than joining them. The
    queue's backing memory outlives the pool itself when workers are
    still winding down; whichever worker exits last frees it from
    `_worker_entry`, so the pool never races a worker for that free.
    """

    var _queue: Pointer[_WorkQueue, MutUntrackedOrigin]
    var _threads: List[_Thread]
    var _wakeup_fd_copy: RawHandle
    var _owns_queue: Bool

    def __init__(out self, *, thread_count: Int = 4) raises:
        """Create a pool and spawn `thread_count` worker threads (1..64).

        On partial spawn failure, threads already running are shut down
        and detached before the error propagates.
        """
        if thread_count < 1 or thread_count > 64:
            raise "thread_count must be between 1 and 64"

        var efd = create_eventfd()
        var queue_ptr = unsafe_alloc[_WorkQueue](1)
        try:
            queue_ptr.unsafe_write(
                _WorkQueue(wakeup_fd=efd, thread_count=thread_count)
            )
        except e:
            queue_ptr.unsafe_free()
            raise e^

        self._queue = queue_ptr
        self._wakeup_fd_copy = efd
        self._threads = List[_Thread]()
        self._owns_queue = True

        var ctx = Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(self._queue)
        )
        for _ in range(thread_count):
            try:
                self._threads.append(
                    _Thread(entry=_worker_entry, context=ctx)
                )
            except e:
                # Some threads may already be running. Shut the queue
                # down so they exit pop() instead of blocking forever,
                # then detach them so they clean up unattended.
                #
                # The queue's active-thread count was seeded with the
                # full `thread_count`, but only `len(self._threads)`
                # workers actually exist. Charge every thread that never
                # got to spawn against that count, exactly as if it had
                # already exited, so the real workers' own exits (or,
                # if none ever spawned, this correction alone) are what
                # bring the count to zero. Freeing the queue here
                # unconditionally would race a real worker thread
                # concurrently exiting and freeing it itself.
                self._queue[].shutdown()
                var never_spawned = thread_count - len(self._threads)
                for j in range(len(self._threads)):
                    self._threads[j].detach()
                self._owns_queue = False
                var is_last = False
                for _attempt in range(never_spawned):
                    if self._queue[].thread_exited():
                        is_last = True
                if is_last:
                    self._queue.unsafe_deinit_pointee()
                    self._queue.unsafe_free()
                raise e^

    def __init__(out self, *, deinit move: Self):
        self._queue = move._queue
        self._threads = move._threads^
        self._wakeup_fd_copy = move._wakeup_fd_copy
        self._owns_queue = move._owns_queue

    def submit(mut self, var item: WorkItem) raises:
        """Enqueue a work item for a worker thread to run."""
        if not self._owns_queue:
            raise "pool is shut down"
        self._queue[].push(item^)

    def drain(mut self) -> List[_CompletedWork]:
        """Clear the wakeup eventfd and return every finished result."""
        drain_eventfd(self._wakeup_fd_copy)
        return self._queue[].drain_results()

    def wakeup_fd(self) -> RawHandle:
        """The eventfd a loop should watch for finished work."""
        return self._wakeup_fd_copy

    def __deinit__(deinit self):
        """Cancel pending work, wake and detach every worker thread.

        Does not free the queue's backing memory: doing so here could
        race a worker thread that observes shutdown and frees the queue
        itself from `_worker_entry` at (nearly) the same instant.
        Pending items are cancelled *before* `shutdown()` runs, while no
        worker can yet be exiting for the shutdown reason, so
        `cancel_pending()` never reads memory a worker might already
        have freed. Whichever worker exits last frees the queue.
        """
        if not self._owns_queue:
            return
        # 1. Drain already-completed results and fire their completions.
        drain_eventfd(self._wakeup_fd_copy)
        var completed = self._queue[].drain_results()
        for i in range(len(completed)):
            completed[i].completion[].fire(Int(completed[i].result), UInt32(0))
        # 2. Cancel unstarted items before shutdown (see docstring).
        var cancelled = self._queue[].cancel_pending()
        for i in range(len(cancelled)):
            cancelled[i].completion[].fire(-125, UInt32(0))  # -ECANCELED
        # 3. Shut down the queue: wakes every worker blocked in pop().
        self._queue[].shutdown()
        # 4. Detach all threads; each cleans up on its own when it exits.
        for i in range(len(self._threads)):
            self._threads[i].detach()
        # 5. Release our pointer without freeing it. The last worker to
        #    exit frees the queue from _worker_entry.
