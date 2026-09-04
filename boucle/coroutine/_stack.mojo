"""Platform-agnostic coroutine stack alias.

Selects the platform-specific backend at compile time,
following the same pattern as RawHandle in the handle layer.
"""

from boucle.socle.platform import _UcontextStack

comptime _CoroStack = _UcontextStack
