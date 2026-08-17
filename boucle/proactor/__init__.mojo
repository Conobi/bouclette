"""Proactor module -- per-operation completion callbacks.

Each I/O operation carries its own callback, enabling heterogeneous
operation types without a match/switch on token values.
"""

from .bufring import BufRing
from .completion import Completion, CompletionFn
from .loop import EventLoop
