"""Boucle — platform-agnostic I/O for Mojo.

The root package exports what an application needs and nothing more:

- `WatchLoop` and its Futures: completion-based I/O, the default model,
  with `Message`/`MessageResult` for datagram operations and the typed
  `TransferFailed`/`MessageFailed` failures that hand buffers back.
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
    FailureReason,
    MessageFailed,
    RecvFuture,
    RecvMsgFuture,
    SendFuture,
    SendMsgFuture,
    TimerFuture,
    TransferFailed,
    TransferResult,
    WatchLoop,
)
from .net import (
    AddrFamily,
    ControlMessage,
    ControlMessages,
    IpAddrV4,
    IpAddrV6,
    Message,
    MessageResult,
    Socket,
    SocketAddrV4,
    SocketAddrV6,
)
from .coroutine import Coroutine, Yielder, StackPool, CoroutineBody
