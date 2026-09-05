"""WatchLoop — ergonomic completion-based I/O with asyncio-style Futures.

Submit an operation, keep the Future it returns, and read its result
once the loop has run. `Backend` is re-exported here because selecting
or inspecting the kernel mechanism (`WatchLoop(backend=Backend.EPOLL)`,
`loop.backend()`) is part of using the loop.
"""

from boucle.drivers.backend import Backend

from .accept import AcceptFuture
from .connect import ConnectFuture
from .connect_timeout import ConnectWithTimeoutFuture
from .loop import WatchLoop
from .outcome import ConnectOutcome
from .recv import RecvFuture
from .recv_msg import RecvMsgFuture
from .send import SendFuture
from .send_msg import SendMsgFuture
from .transfer import FailureReason, MessageFailed, TransferFailed, TransferResult
from .timer import TimerFuture
