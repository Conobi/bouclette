"""DEPRECATED: Use boucle.coroutine instead."""

from boucle.coroutine.handle import Coroutine as CoroHandle
from boucle.coroutine.yielder import CoroutineBody as CoroBody
from boucle.coroutine.yielder import Yielder as CoroYielder
from boucle.coroutine.yielder import _CoroInner
from boucle.coroutine._state import (
    CORO_CREATED,
    CORO_RUNNING,
    CORO_SUSPENDED,
    CORO_DONE,
    CORO_MAGIC,
    DEFAULT_STACK_SIZE,
)
from boucle.coroutine.pool import CoroutinePool
