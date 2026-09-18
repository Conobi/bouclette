"""Worker pool for dispatching blocking work to OS threads."""

from bouclette.pool.pool import WorkerPool
from bouclette.pool._queue import WorkItem, _CompletedWork
