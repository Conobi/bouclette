"""Platform-specific I/O driver implementations.

Each driver implements the IoDriver trait from boucle.drivers.driver,
providing the proactor with a uniform submit/tick interface regardless
of the underlying kernel mechanism.
"""

from .driver import IoDriver, ReadinessDriver
from .readiness_event import ReadinessEvent
from .io_uring import IoUringDriver
from .epoll import EpollDriver

# Comptime aliases — the singular dispatch point for platform selection
comptime _CompletionDriver = IoUringDriver
comptime _ReadinessDriver = EpollDriver
