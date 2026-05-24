![CI](https://github.com/Conobi/boucle/actions/workflows/ci.yml/badge.svg)

# Boucle

Boucle is a platform-agnostic I/O foundation for Mojo. It exposes two explicit async I/O models — **completion** (submit work, get notified when done) and **readiness** (get notified when I/O is possible, do it yourself) — over shared portable types (sockets, buffers, handles, addresses). Boucle is sans-I/O compatible: protocol libraries (HTTP, QUIC) stay framework-free and compose with either loop at the application level. Today's backends are Linux io_uring (completion) and Linux epoll (readiness), with macOS kqueue and Windows IOCP planned.

## When to use which model

### Prefer completion when
- Bulk data transfer (file serving, streaming)
- Batching many operations (databases, storage engines)
- Cancellation is rare
- Heavy disk I/O (io_uring does real async file I/O)

### Prefer readiness when
- Multiplexed connections (HTTP/2, HTTP/3, QUIC)
- Frequent cancellation (timeouts, request racing, hedging)
- Fine-grained stream prioritization
- Many idle connections (classic C10K)

## Install & build

```bash
uv sync                                # Install dev dependencies
uv run -- bash scripts/build.sh        # Build boucle.mojopkg
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

### Completion echo (loopback TCP via io_uring)

```mojo
var loop = CompletionLoop(EchoTracker(), sq_entries=8)
loop.submit_accept(server.raw(), token=_TOK_ACCEPT)
loop.submit_connect(client.raw(), addr_ptr, addr_len, token=_TOK_CONNECT)
loop.run()

loop.submit_send(client.raw(), send_buf, UInt(_MSG_LEN), token=_TOK_SEND)
loop.submit_recv(accepted_fd, recv_ptr, UInt(16), token=_TOK_RECV)
loop.run()

assert_equal(loop._handler.bytes_recvd, Int32(_MSG_LEN))
```

```bash
uv run -- mojo run -I . -D ASSERT=all examples/completion_echo.mojo
```

### Readiness echo (pipe via epoll)

```mojo
var loop = ReadinessLoop(EchoHandler(read_fd), max_events=16)
loop.register(read_fd, Interest.READABLE, Token(42))

# Write the message; the kernel will mark the read end readable.
_ = syscall[1, Scalar[DType.int64]](write_fd, msg_ptr, UInt64(_MSG_LEN))

loop.poll(timeout_ms=1000)
assert_equal(loop._handler.bytes_read, _MSG_LEN)
```

```bash
uv run -- mojo run -I . -D ASSERT=all examples/readiness_echo.mojo
```

### Coro echo (stackful yield/resume)

```mojo
def _echo_body(mut y: CoroYielder) raises:
    print("in coro")
    y.yield_to_caller()
    print("resumed")

var coro = CoroHandle(_echo_body)
print("before resume")
coro.resume()
print("after first resume")
coro.resume()
assert_true(coro.is_done())
```

```bash
uv run -- mojo run -I . -D ASSERT=all examples/coro_echo.mojo
```

## Architecture

```
boucle/                              # Public API — what developers import
├── completion.mojo                  # CompletionLoop, CompletionHandler
├── readiness.mojo                   # ReadinessLoop, ReadinessHandler
├── waker.mojo                       # Waker trait (bridges I/O → executor)
├── coroutine.mojo                   # Coroutine trait (aligned with structured async proposal)
├── executor.mojo                    # Executor traits wrapping loops
├── pending.mojo                     # Linear PendingOp for safe completion cancellation
├── handle.mojo                      # ResourceHandle, OwnedHandle, RawHandle
├── buffer.mojo                      # Buffer types (owned, borrowed, ring)
├── token.mojo                       # Token for event correlation
├── interest.mojo                    # Interest flags (READABLE, WRITABLE)
├── readiness_state.mojo             # Readiness flags (is_readable, is_writable)
├── error.mojo                       # Unified I/O error types
├── net/                             # Platform-agnostic networking types
│   ├── socket.mojo                  # Socket (TCP, UDP, Unix) — portable API
│   ├── addr.mojo                    # SocketAddrV4, SocketAddrV6
│   ├── ip.mojo                      # IpAddrV4, IpAddrV6
│   └── options.mojo                 # Portable socket options only
├── time/                            # Timeout, Deadline
└── _sys/                            # Private platform backends (never import directly)
    ├── linux/
    │   ├── raw/                     # Syscalls, ctypes (x86_64)
    │   ├── io_uring/                # CompletionLoop backend
    │   └── epoll/                   # ReadinessLoop backend
    ├── darwin/                      # Future
    │   └── kqueue/                  # ReadinessLoop backend
    └── windows/                     # Future
        └── iocp/                    # CompletionLoop backend
```

The `_sys/` tree is private — never import from it directly. The backend is selected at compile time based on platform. Platform-specific features (sendmmsg, SO_REUSEPORT) require explicit opt-in from `_sys/` so the import path makes the portability trade-off visible.

## License

MIT. See [`LICENSE`](LICENSE).
