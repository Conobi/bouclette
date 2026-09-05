"""Platform-specific I/O driver implementations.

Each driver implements the IoDriver trait from boucle.drivers.driver,
providing the proactor with a uniform submit/tick interface regardless
of the underlying kernel mechanism.
"""

from .driver import IoDriver, ReadinessDriver
from .readiness_event import ReadinessEvent
from .backend import Backend
from .feature import DriverFeature
from .io_uring import IoUringDriver
from .epoll import EpollDriver
from .epoll_completion import EpollCompletionDriver
from .auto import AutoDriver

comptime _CompletionDriver = AutoDriver
comptime _WatchDriver = AutoDriver
comptime _ReadinessDriver = EpollDriver
