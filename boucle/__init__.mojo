"""Boucle — platform-agnostic I/O for Mojo.

The root package exports what an application needs and nothing more:

- `WatchLoop` and its Futures, plus `BufferPool` and `DatagramStream`
  for multishot receives: completion-based I/O, the default model, with
  `Message`/`MessageResult` for datagram operations, `AlignedBuffer` for
  file I/O, and the typed `TransferFailed`/`MessageFailed`/`FileTransferFailed`
  failures that hand buffers back.
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
from .buffer import AlignedBuffer
from .watch import (
    AcceptFuture,
    BufferPool,
    ConnectFuture,
    ConnectOutcome,
    ConnectWithTimeoutFuture,
    Datagram,
    DatagramStream,
    FailureReason,
    FileTransferFailed,
    FileTransferResult,
    FsyncFuture,
    LeasedBuffer,
    MessageFailed,
    ReadFileFuture,
    RecvFuture,
    RecvMsgFuture,
    SendFuture,
    SendMsgFuture,
    TimerFuture,
    TransferFailed,
    TransferResult,
    WatchLoop,
    WriteFileFuture,
)
from .net import (
    AddrFamily,
    ControlMessage,
    ControlMessages,
    DeliveryHeader,
    IpAddrV4,
    IpAddrV6,
    Message,
    MessageResult,
    Socket,
    SocketAddrV4,
    SocketAddrV6,
)
from .coroutine import Coroutine, Yielder, StackPool, CoroutineBody
