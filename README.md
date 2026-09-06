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

- **Two models, one type system.** `WatchLoop` (completion: submit work, get notified) and `ReadinessLoop` (readiness: get notified, do the I/O yourself) share `Socket`, `SocketAddrV4`/`SocketAddrV6`, `IOError` and `Backend`. No adapter layers.
- **Sans-I/O compatible.** Zero protocol opinions. Protocol libraries (HTTP, QUIC) stay framework-free and compose with either loop at the application level.
- **Automatic backend selection.** `Backend.AUTO` picks io_uring only when the kernel serves the datagram path natively (multishot recvmsg and provided-buffer rings, 6.0+), epoll otherwise. A single binary works across kernel versions.
- **The loop owns in-flight buffers.** `send`/`recv` take the buffer *by value* and `send_msg`/`recv_msg` take a `Message` the same way. While the kernel reads or writes it, nothing else can touch or free it; `result()` hands it back with the byte count, and a failed operation hands it back inside the typed `TransferFailed`/`MessageFailed` error. Dropping the future without running the loop is harmless.
- **One errno type.** Every failure carries an `IOError` with the errno, printing as `ECONNREFUSED (111)`. `Socket` calls raise it directly; the completion futures wrap it in `TransferFailed`/`MessageFailed` so the in-flight buffer rides back with the error.
- **`socle/` is private.** OS abstractions (syscalls, fd, errno, epoll/io_uring wrappers) live in `boucle/socle/`, and `boucle/socle/platform.mojo` is the single seam where the portable layer names a concrete OS. Platform-specific features require an explicit `socle/` import — the path makes the portability trade-off visible.
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

For a feature-by-feature comparison with mio, libuv, compio, monoio, libxev and
TigerBeetle's I/O layer, including where Boucle is behind, see
[`docs/feature-comparison.md`](docs/feature-comparison.md).

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
| [`readiness_echo.mojo`](examples/readiness_echo.mojo) | Loopback TCP echo via ReadinessLoop (register, tick, read). |
| [`coro_echo.mojo`](examples/coro_echo.mojo) | Stackful coroutine yield/resume with typed state. |
| [`port_scan.mojo`](examples/port_scan.mojo) | TCP port scanner using WatchLoop's connect-with-timeout. |

Same run pattern for all of them:

```bash
uv run -- mojo run -I . -D ASSERT=all examples/completion_echo.mojo
```

## Use as a library

### Completion — `WatchLoop`

Submit operations, call `run()`, read the results out of the futures it handed you.

```mojo
from boucle import Backend, IOError, Socket, SocketAddrV4, WatchLoop
from boucle.net.options import Backlog


def main() raises:
    var server = Socket.tcp_v4()
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)
    var port = server.local_addr_v4().port

    var client = Socket.tcp_v4()

    var loop = WatchLoop(capacity=8, backend=Backend.AUTO)
    var accept_f = loop.accept(server)
    var connect_f = loop.connect(client, SocketAddrV4(127, 0, 0, 1, port=port))
    loop.run()

    var peer = accept_f.result()
    _ = connect_f.result()

    # Buffers move into the loop. Nothing else can read, write or free
    # them while the kernel works; result() hands them back.
    var send_f = loop.send(client, List[UInt8](length=5, fill=UInt8(ord("x"))))
    var recv_f = loop.recv(peer, List[UInt8](length=32, fill=0))
    loop.run()

    var sent = send_f^.result()
    var got = recv_f^.result()
    print("sent", sent.count, "got", got.count, "bytes")
    print("echoed:", String(from_utf8=got.transferred()))

    var buf = got^.take_buffer()  # the buffer, back under your ownership
    print("capacity still", len(buf))

    try:
        _ = Socket.tcp_connect(SocketAddrV4(127, 0, 0, 1, port=1))
    except e:
        print("typed failure:", e)

    peer.close()
    client.close()
    server.close()
```

```
sent 5 got 5 bytes
echoed: xxxxx
capacity still 32
typed failure: ECONNREFUSED (111)
```

**Buffer ownership.** `recv`/`send` take `var buf: List[UInt8]`, so the loop owns the bytes for exactly as long as the operation is in flight. You get them back from `result()` as a `TransferResult`: `count` bytes moved, `transferred()` is a span over them, `take_buffer()` returns the list itself. The buffer's *length* is the recv window — a list of length 32 asks for at most 32 bytes — and the length is not changed by the operation. Dropping a future instead of calling `result()` simply gives the buffer up.

**Datagrams.** `send_msg`/`recv_msg` take a `Message`: a payload list, an optional peer (`set_peer`) and a control area (`control_capacity`). `send_to(socket, buf, addr)` and `recv_from(socket, buf)` are the two-line wrappers. The `MessageResult` carries `count`, `peer_v4()`/`peer_v6()`, `control()` (a walker over cmsg records, with `ecn()` for the codepoint), `truncated()`/`control_truncated()`, and `take_message()`. To receive ECN, call `socket.set_recv_tos()` and give the receiving message at least 24 bytes of control capacity; to send it, `msg.set_ecn(mark)` after `set_peer` (a v4-mapped v6 peer gets an `IP_TOS` record, as the kernel requires); `set_ecn` replaces whatever the control area held, it never appends. `recv_msg` on a datagram socket reports the full datagram length even past the window; on a stream socket it reports the bytes copied and discards nothing.

**Multishot datagrams.** `loop.buffer_pool(count, size)` returns a `BufferPool` the loop owns; `loop.recv_msg_multishot(socket, pool)` returns a `DatagramStream` that keeps receiving into that pool until dropped or ended. `stream.next()` yields a `Datagram` — payload span, `peer_v4()`/`peer_v6()`, `control()` — whose `LeasedBuffer` goes back to the pool when it is dropped. Drive the stream with `loop.step()`, not `run()`: `run()` returns as soon as no one-shot operation is pending. When every buffer is leased the stream ends with `ENOBUFS` — `armed()` turns False and `error()` is set — and `rearm()` resumes it once leases have been dropped. `buffer_pool` accepts a count in 1..32768 (rounded up to a power of two) and a size from 64 bytes to 16 MiB; anything else raises `IOError(EINVAL)`.

**Failures return the buffer.** `RecvFuture.result()`/`SendFuture.result()` raise `TransferFailed`; the message futures raise `MessageFailed`. `reason` is `IO` (errno in `error`, buffer recoverable with `take_buffer()`/`take_message()`), `NOT_DONE` (called before the loop ran; the loop still owns the buffer) or `LOOP_GONE` (the loop was destroyed first; the buffer was abandoned). The submitting verbs raise the same types: `loop.recv`/`loop.send` raise `TransferFailed` and `recv_msg`/`send_msg`/`send_to`/`recv_from` raise `MessageFailed`, always with reason `IO` and the buffer or message inside, when the socket handle is invalid or the driver refuses the submission; nothing stays in flight in that case.

**Lifetimes.** Sockets are *not* moved into the loop: they must stay alive across `run()`, and you close them yourself.

### Readiness — `ReadinessLoop`

You implement a `ReadinessHandler`; the loop tells you when I/O is possible and you perform it. `on_ready` receives the loop's `ReadinessRegistry` by `mut`, so re-arming, changing interest or deregistering is an ordinary method call — no pointer to the loop.

```mojo
from boucle import (
    Interest,
    Readiness,
    ReadinessHandler,
    ReadinessLoop,
    ReadinessRegistry,
    Socket,
    SocketAddrV4,
    Token,
)
from boucle.net.options import Backlog


struct EchoHandler(ReadinessHandler):
    """Reads whatever arrives, then drops its own registration."""

    var peer: Socket
    var bytes_read: Int

    def __init__(out self, var peer: Socket):
        self.peer = peer^
        self.bytes_read = 0

    def __init__(out self, *, deinit move: Self):
        self.peer = move.peer^
        self.bytes_read = move.bytes_read

    def on_ready(
        mut self,
        mut registry: ReadinessRegistry,
        token: Token,
        readiness: Readiness,
    ):
        if readiness.is_readable():
            var buf = InlineArray[UInt8, 64](fill=0)
            # on_ready cannot raise: handle I/O errors here.
            try:
                self.bytes_read = self.peer.recv(buf)
            except e:
                print("read failed:", e)
            try:
                registry.deregister(self.peer)
            except e:
                print("deregister failed:", e)


def main() raises:
    var server = Socket.tcp_v4()
    server.set_blocking(True)
    server.bind(SocketAddrV4(127, 0, 0, 1, port=0))
    server.listen(Backlog.DEFAULT)
    var port = server.local_addr_v4().port

    var client = Socket.tcp_connect(SocketAddrV4(127, 0, 0, 1, port=port))
    var peer = server.accept()

    # Register first, then hand the populated registry to the loop.
    var registry = ReadinessRegistry(capacity=16)
    registry.register(peer, Interest.READABLE, Token(1))
    var loop = ReadinessLoop(EchoHandler(peer^), registry^)

    _ = client.send(String("hello").as_bytes())
    loop.run_once(timeout_ms=1000)

    print("read", loop.handler().bytes_read, "bytes")

    client.close()
    server.close()
```

```
read 5 bytes
```

Read handler state back with `loop.handler()`; reach the interest set from outside a callback with `loop.registry()`, or use the `register` / `modify` / `deregister` methods the loop forwards. The `_raw` variants of each take a bare file descriptor for pipes and timerfds.

### Driving a loop

| Verb | Meaning | Where |
|---|---|---|
| `run()` | Block until every submitted operation has completed, then return (drain). | `WatchLoop` |
| `step(timeout_ms)` | Drive one bounded tick, for long-lived work that re-arms itself (e.g. a datagram stream). | `WatchLoop` |
| `run_forever()` | Loop until `stop()` is called. | `CompletionLoop`, `EventLoop` |
| `run_once()` | One blocking tick. | `CompletionLoop`, `EventLoop`, `ReadinessLoop` (with an optional `timeout_ms`) |
| `poll()` | One non-blocking tick. | `CompletionLoop`, `EventLoop`, `ReadinessLoop` |

There is nothing to run forever on a `WatchLoop`, whose unit of work is a set of futures; there is nothing to drain on a loop whose work is an open-ended stream of events.

Capacity is a hint everywhere and is spelled `capacity=`; every timeout is milliseconds and is spelled `timeout_ms=`.

### Escape hatch

`boucle.proactor.CompletionLoop` is the raw, pointer-level completion API that `WatchLoop` is built on: every operation takes a caller-owned `Completion` and bare pointers, with no typed results and no buffer ownership. It exists for backends and for callers who need to bypass the future machinery — it is not the completion model users should reach for.

---

## Project layout

```
boucle/                              Public API — what developers import
├── watch/                           Completion model: WatchLoop + asyncio-style Futures
│   ├── loop.mojo                    WatchLoop (accept, connect, connect_with_timeout,
│   │                                recv, send, recv_msg, send_msg, recv_from, send_to,
│   │                                timeout, buffer_pool, recv_msg_multishot, run, step)
│   ├── accept.mojo                  AcceptFuture
│   ├── connect.mojo                 ConnectFuture
│   ├── connect_timeout.mojo         ConnectWithTimeoutFuture (composite connect+timer)
│   ├── recv.mojo                    RecvFuture
│   ├── send.mojo                    SendFuture
│   ├── recv_msg.mojo                RecvMsgFuture
│   ├── send_msg.mojo                SendMsgFuture
│   ├── timer.mojo                   TimerFuture
│   ├── transfer.mojo                TransferResult, TransferFailed, MessageFailed, FailureReason
│   ├── outcome.mojo                 ConnectOutcome
│   ├── pool.mojo                    BufferPool, LeasedBuffer (loop-owned receive buffers)
│   ├── stream.mojo                  Datagram, DatagramStream (multishot recvmsg)
│   ├── _shared.mojo                 Driver pointer, liveness and tally shared with slab states
│   ├── _callback.mojo               Internal future-state ownership hooks
│   ├── _message.mojo                Slab-owned msghdr state behind the message futures
│   └── _slab.mojo                   Per-kind chunked slab of operation states
├── readiness.mojo                   Readiness model: ReadinessLoop, ReadinessRegistry,
│                                    ReadinessHandler
├── proactor/                        Raw completion plumbing under watch/
│   ├── completion_loop.mojo         CompletionLoop — pointer-level escape hatch
│   ├── loop.mojo                    EventLoop — single-threaded completion-driven loop
│   └── completion.mojo              Completion, CompletionFn (per-operation callback)
├── drivers/                         Backend implementations + auto-detection
│   ├── driver.mojo                  IoDriver, ReadinessDriver traits
│   ├── auto.mojo                    AutoDriver (io_uring, falling back to epoll)
│   ├── backend.mojo                 Backend (AUTO, IO_URING, EPOLL)
│   ├── feature.mojo                 DriverFeature (multishot recvmsg, buffer ring, ...)
│   ├── io_uring.mojo                IoUringDriver (completion)
│   ├── epoll_completion.mojo        EpollCompletionDriver (completion over epoll)
│   ├── epoll.mojo                   EpollDriver (readiness)
│   ├── bufring.mojo                 Provided-buffer ring for zero-copy recv
│   └── readiness_event.mojo         ReadinessEvent (token + readiness)
├── coroutine/                       Stackful coroutines (bridge until Mojo async)
│   ├── handle.mojo                  Coroutine[State] — typed handle, cancel(), close()
│   ├── yielder.mojo                 Yielder, CoroutineBody
│   ├── pool.mojo                    StackPool — free-list of reusable stacks
│   ├── _stack.mojo                  Comptime-selected platform stack backend
│   └── _state.mojo                  Coroutine phase type and defaults
├── net/                             Platform-agnostic networking types
│   ├── socket.mojo                  Socket (TCP, UDP — bind, listen, accept, connect,
│   │                                recv, send)
│   ├── addr.mojo                    SocketAddrV4, SocketAddrV6
│   ├── ip.mojo                      IpAddrV4, IpAddrV6
│   ├── message.mojo                 Message, MessageResult, ControlMessages, DeliveryHeader
│   └── options.mojo                 Portable socket options (Backlog, Shutdown, flags)
├── error.mojo                       IOError — the one error type I/O raises
├── handle.mojo                      RawHandle, OwnedHandle
├── token.mojo                       Token for readiness event correlation
├── interest.mojo                    Interest flags (READABLE, WRITABLE)
├── readiness_state.mojo             Readiness flags (is_readable, is_writable)
├── timeout.mojo                     Timeout — internal timespec for kernel timers
├── ctypes/                          C scalar aliases for callers wiring external_call
└── socle/                           Private platform layer (never import directly)
    ├── platform.mojo                The one seam where the portable layer names an OS
    ├── ptr.mojo                     null_ptr — a genuine NULL Pointer
    └── linux/
        ├── raw/                     Arch-dispatched syscalls (x86_64, aarch64), ctypes
        ├── io_uring/                Ring setup, SQ/CQ, ops, memory mapping
        ├── epoll/                   epoll syscall wrappers
        ├── net/                     Socket syscall wrappers
        ├── abi.mojo                 Arch-specific calling conventions
        ├── errno.mojo               Errno and result decoders
        ├── fd.mojo                  File-descriptor primitives
        ├── mm.mojo                  Memory mapping (mmap, munmap, mprotect)
        ├── ucontext.mojo            ucontext wrappers (getcontext, makecontext, swapcontext)
        ├── ucontext_stack.mojo      RAII coroutine stack (guard page, context setup)
        ├── uname.mojo               uname(2) wrapper, KernelVersion (major.minor)
        └── utils.mojo               Internal helpers
```

## License

[MIT](LICENSE)
