"""Worker pool for dispatching blocking work to OS threads."""

from boucle.pool.pool import WorkerPool
from boucle.pool._queue import WorkItem, _CompletedWork
