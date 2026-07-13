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
- **Token-based completion routing.** Each submitted operation carries a user token. The loop tracks pending operations and invokes the handler with the token, result, and flags on completion. Coroutines use `@explicit_destroy` — you must call `destroy()`, preventing silent resource leaks.
- **`_sys/` is private.** The backend is selected at compile time. Platform-specific features (sendmmsg, SO_REUSEPORT) require an explicit `_sys/` import — the path makes the portability trade-off visible.
- **Stackful coroutines.** Real yield/resume via `ucontext` — no state machine transform. Coroutines run on their own stack and suspend cooperatively.
- **Portable by design.** The architecture supports multiple backends per platform. Currently Linux-only (io_uring + epoll); macOS (kqueue) and Windows (IOCP) are planned.

### Platform coverage

| Backend | Model | Platform | Status |
|---|---|---|---|
| io_uring | Completion | Linux | ✅ |
| epoll | Readiness | Linux | ✅ |
| kqueue | Readiness | macOS | Planned |
| kqueue (emulated) | Completion | macOS | Planned |
| IOCP | Completion | Windows | Planned |
| IOCP (emulated) | Readiness | Windows | Planned |

---

## Install / build

```bash
uv sync                                # Install dev dependencies
uv run -- bash scripts/build.sh        # Build boucle.mojoc
```

## Run tests

```bash
uv run -- bash scripts/run_tests.sh
```

Single test:

```bash
uv run -- mojo run -I . -D ASSERT=all tests/<path>.mojo
```

## Examples

Each example is a self-contained, runnable Mojo program. They live in `examples/` and are not in the test runner — invoke them directly.

| Example | What it does |
|---|---|
| [`completion_echo.mojo`](examples/completion_echo.mojo) | Loopback TCP echo via io_uring (accept, connect, send, recv). |
| [`readiness_echo.mojo`](examples/readiness_echo.mojo) | Pipe echo via epoll (register, poll, read). |
| [`coro_echo.mojo`](examples/coro_echo.mojo) | Stackful coroutine yield/resume. |

Same run pattern for all of them:

```bash
uv run -- mojo run -I . -D ASSERT=all examples/completion_echo.mojo
```

## Use as a library

You write a handler that implements `CompletionHandler` or `ReadinessHandler`; the loop owns the kernel interface:

```mojo
from boucle.completion import CompletionLoop, CompletionHandler

comptime _TOK_RECV: UInt64 = 4

struct EchoTracker(CompletionHandler):
    var bytes_recvd: Int32

    def __init__(out self):
        self.bytes_recvd = 0

    def __init__(out self, *, deinit take: Self):
        self.bytes_recvd = take.bytes_recvd

    def on_complete(mut self, token: UInt64, result: Int32, flags: UInt32):
        if token == _TOK_RECV:
            self.bytes_recvd = result
```

The same handler shape drives `ReadinessHandler` for epoll. For the full wiring (socket setup, submit/run cycle, assertions) see [`examples/completion_echo.mojo`](examples/completion_echo.mojo).

---

## Project layout

```
boucle/        Mojo source (public API)
├── completion.mojo      CompletionLoop, CompletionHandler
├── readiness.mojo       ReadinessLoop, ReadinessHandler
├── stackful.mojo        Stackful coroutines (CoroHandle, CoroYielder)
├── handle.mojo          ResourceHandle, OwnedHandle, RawHandle
├── buffer.mojo          Buffer types (owned, borrowed, ring)
├── token.mojo           Token for event correlation
├── interest.mojo        Interest flags (READABLE, WRITABLE)
├── readiness_state.mojo Readiness flags
├── error.mojo           Unified I/O error types
├── ctypes/              Public bridge for C types (c_void, etc.)
├── net/                 Platform-agnostic networking types
│   ├── socket.mojo      Socket (TCP, UDP, Unix)
│   ├── addr.mojo        SocketAddrV4, SocketAddrV6
│   ├── ip.mojo          IpAddrV4, IpAddrV6
│   └── options.mojo     Portable socket options
└── _sys/                Private platform backends
    └── linux/
        ├── raw/         Arch-dispatched syscalls and ctypes
        ├── io_uring/    CompletionLoop backend
        └── epoll/       ReadinessLoop backend
```

## License

[MIT](LICENSE)
