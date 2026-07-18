"""Platform-specific I/O driver implementations.

Each driver implements the IoDriver trait from boucle.proactor.driver,
providing the proactor with a uniform submit/tick interface regardless
of the underlying kernel mechanism.
"""

from .io_uring import IoUringDriver
