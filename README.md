<h1 align="center">
  🔁<br/>
  Boucle
</h1>

<p align="center">
  <i>Platform-agnostic I/O foundation for Mojo: completion and readiness loops over shared portable types.</i>
</p>

> [!WARNING]
> **Active development — not production-ready.**
> APIs are unstable, and the only supported backends are `io_uring` and `epoll` on Linux.
---

## Why Boucle

Most I/O libraries pick one model and emulate the other. Boucle exposes both as first-class APIs over shared types, so you pick the model that fits your workload — not the one your library chose for you.

- **Two models, one type system.** Completion (submit work, get notified) and readiness (get notified, do it yourself) share Socket, Buffer, Token, SocketAddr. No adapter layers.
- **Sans-I/O compatible.** Zero protocol opinions. Protocol libraries (HTTP, QUIC) stay framework-free and compose with either loop at the application level.
- **Automatic backend selection.** `Backend.AUTO` picks io_uring when the kernel supports it, falls back to epoll otherwise. A single binary works across kernel versions.
- **`socle/` is private.** OS abstractions (syscalls, fd, errno, epoll/io_uring wrappers) live in `boucle/socle/`. The backend is selected at compile time. Platform-specific features require an explicit `socle/` import — the path makes the portability trade-off visible.
- **Stackful coroutines.** Real yield/resume via `ucontext` — no state machine transform. Coroutines run on their own stack and suspend cooperatively. Temporary bridge until Mojo ships native async/await.
- **Portable by design.** The architecture supports multiple backends per platform. Currently Linux-only (io_uring + epoll); macOS (kqueue) and Windows (IOCP) are planned.

### Platform coverage

| Backend | Model | Platform | Status |
|---|---|---|---|
| io_uring | Completion | Linux | ✅ |
| epoll | Readiness | Linux | ✅ |
| epoll (emulated) | Completion | Linux | ✅ |
| kqueue | Readiness | macOS | Planned |
| kqueue (emulated) | Completion | macOS | Planned |
| IOCP | Completion | Windows | Planned |
| IOCP (emulated) | Readiness | Windows | Planned |

---

## Install / build

```bash
uv sync                                                        # Install dev dependencies
uv run mojox check                                             # Type-check / compile boucle
```

## Run tests

```bash
uv run mojox test                                              # Run all tests (parallel)
uv run mojox test --no-fail-fast                               # Run all tests, don't stop on first failure
```

Single test:

```bash
uv run -- mojo run -I . -D ASSERT=all tests/<path>.mojo
```

## Examples

Each example is a self-contained, runnable Mojo program. They live in `examples/` and are not part of the test suite — invoke them directly.

| Example | What it does |
|---|---|
| [`completion_echo.mojo`](examples/completion_echo.mojo) | Loopback TCP echo via WatchLoop (accept, connect, send, recv). |
| [`readiness_echo.mojo`](examples/readiness_echo.mojo) | Pipe echo via ReadinessLoop (register, poll, read). |
| [`coro_echo.mojo`](examples/coro_echo.mojo) | Stackful coroutine yield/resume with typed state. |
| [`port_scan.mojo`](examples/port_scan.mojo) | TCP port scanner using WatchLoop's connect-with-timeout. |

Same run pattern for all of them:

```bash
uv run -- mojo run -I . -D ASSERT=all examples/completion_echo.mojo
```

## Use as a library

WatchLoop wraps the platform completion backend behind asyncio-style Futures. Submit operations, call `run()`, extract results:

```mojo
from boucle.watch import WatchLoop
from boucle.net.socket import Socket
from boucle.net.addr import SocketAddrV4
from boucle.net.options import Backlog

def main() raises:
    var server = Socket.tcp_v4()
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)

    var port = server.local_addr_v4().port

    var client = Socket.tcp_v4()

    var loop = WatchLoop()
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, SocketAddrV4(127, 0, 0, 1, port=port))
    loop.run()

    var peer = accept_f.result()
    _ = connect_f.result()

    # Sockets must stay alive through loop.run(); close explicitly.
    peer.close()
    client.close()
    server.close()
```

For readiness-driven I/O (epoll), you implement a `ReadinessHandler` — the loop tells you when I/O is possible, you perform it yourself. See [`readiness_echo.mojo`](examples/readiness_echo.mojo) for the full pattern.

---

## Project layout

```
boucle/                              Public API — what developers import
├── watch/                           WatchLoop + asyncio-style Futures
│   ├── loop.mojo                    WatchLoop (run, accept, connect, recv, send, timeout)
│   ├── accept.mojo                  AcceptFuture
│   ├── connect.mojo                 ConnectFuture
│   ├── connect_timeout.mojo         ConnectWithTimeoutFuture
│   ├── recv.mojo                    RecvFuture
│   ├── send.mojo                    SendFuture
│   ├── timer.mojo                   TimerFuture
│   └── outcome.mojo                 ConnectOutcome
├── completion.mojo                  CompletionLoop (lower-level token-based API)
├── readiness.mojo                   ReadinessLoop, ReadinessHandler
├── coroutine/                       Stackful coroutines (bridge until Mojo async)
│   ├── handle.mojo                  Coroutine[State] — typed, cancel(), close()
│   ├── yielder.mojo                 CoroYielder[State]
│   └── pool.mojo                    StackPool
├── drivers/                         Backend implementations + auto-detection
│   ├── backend.mojo                 Backend enum (IO_URING, EPOLL, AUTO)
│   ├── driver.mojo                  CompletionDriver trait
│   ├── io_uring.mojo                IoUringDriver
│   ├── epoll_completion.mojo        EpollCompletionDriver (completion over epoll)
│   └── epoll.mojo                   EpollDriver (readiness)
├── proactor/                        Proactor loop (drives CompletionDriver)
│   ├── loop.mojo                    ProactorLoop
│   └── completion.mojo              Completion callback type
├── handle.mojo                      ResourceHandle, OwnedHandle, RawHandle
├── buffer.mojo                      Buffer types (owned, borrowed, ring)
├── token.mojo                       Token for event correlation
├── interest.mojo                    Interest flags (READABLE, WRITABLE)
├── readiness_state.mojo             Readiness flags
├── error.mojo                       Unified I/O error types
├── net/                             Platform-agnostic networking types
│   ├── socket.mojo                  Socket (TCP, UDP — bind, listen, accept, connect, recv, send)
│   ├── addr.mojo                    SocketAddrV4, SocketAddrV6
│   ├── ip.mojo                      IpAddrV4, IpAddrV6
│   └── options.mojo                 Portable socket options
└── socle/                           Private platform backends (never import directly)
    └── linux/
        ├── raw/                     Arch-dispatched syscalls (x86_64, aarch64) and ctypes
        ├── io_uring/                io_uring ring management, SQ/CQ, ops, memory mapping
        ├── epoll/                   epoll syscall wrappers
        ├── net/                     Socket syscall wrappers
        ├── abi.mojo                 Arch-specific calling conventions
        ├── mm.mojo                  Memory mapping (mmap, munmap, mprotect)
        ├── ucontext.mojo            ucontext wrappers (getcontext, makecontext, swapcontext)
        └── ucontext_stack.mojo      RAII coroutine stack (guard page, context setup)
```

## License

[MIT](LICENSE)
