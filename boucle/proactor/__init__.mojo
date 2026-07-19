"""Proactor module — per-operation completion callbacks.

Alternative to the centralized CompletionHandler dispatch in
boucle.completion. Each I/O operation carries its own callback,
enabling heterogeneous operation types without a match/switch
on token values.
"""

from .bufring import BufRing
from .completion import Completion, CompletionFn
from .driver import IoDriver
from .loop import EventLoop
