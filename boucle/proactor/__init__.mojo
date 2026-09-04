"""Proactor internals — per-operation completion callbacks.

Each I/O operation carries its own callback, so a single loop can drive
heterogeneous operation types without a match on token values. This is
the layer `boucle.watch` is built on: `CompletionLoop` is the raw,
pointer-level escape hatch, `WatchLoop` is the API users should reach
for first.
"""

from .completion import Completion, CompletionFn
from .completion_loop import CompletionLoop
from .loop import EventLoop
