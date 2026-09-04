"""Boucle — platform-agnostic I/O for Mojo.

The root package exports what an application needs and nothing more:

- `WatchLoop` and its Futures: completion-based I/O, the default model.
- `ReadinessLoop`, `Interest`, `Readiness`, `Token`: readiness-based I/O.
- `Socket` and the address types: the portable networking surface.
- `Coroutine` and friends: stackful coroutines driven by either loop.
- `Backend`: which kernel mechanism a loop uses.

Platform backends live under `boucle.socle` and `boucle.drivers`, and
the raw pointer-level completion API under `boucle.proactor`. Neither
is reachable from here — importing them is an explicit opt-in to a
non-portable or unsafe surface.
"""

from .handle import RawHandle, OwnedHandle
from .token import Token
from .error import IOError
from .interest import Interest
from .readiness_state import Readiness
from .readiness import ReadinessLoop, ReadinessHandler, ReadinessRegistry
from .drivers.backend import Backend
from .watch import (
    AcceptFuture,
    ConnectFuture,
    ConnectOutcome,
    ConnectWithTimeoutFuture,
    RecvFuture,
    SendFuture,
    TimerFuture,
    TransferResult,
    WatchLoop,
)
from .net import (
    IpAddrV4,
    IpAddrV6,
    Socket,
    SocketAddrV4,
    SocketAddrV6,
)
from .coroutine import Coroutine, Yielder, StackPool, CoroutineBody
