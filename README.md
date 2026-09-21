<h1 align="center">
  🔁<br/>
  Bouclette
</h1>

<p align="center">
  <i>Platform-agnostic I/O for Mojo.</i>
</p>

> [!WARNING]
> **Active development — not production-ready.**
> APIs are still unstable, and the only supported backends are `io_uring` and `epoll` on Linux.
---

bouclette (pronounced *booklet*, `/bu.klɛt/`) is a lightweight I/O library for Mojo. Backend-agnostic, modern Linux features, zero unnecessary abstractions.

- Dual I/O models
- Auto backend fallback
- Owned in-flight buffers
- Zero-copy recv
- Multishot datagrams
- Batched datagram send (sendmmsg)
- Sans-I/O composable
- Stackful coroutines
- Slab allocation
- GSO / GRO / ECN
- Timer cancel + reset

### Platform coverage

| Backend | Model | Platform | Status |
|---|---|---|---|
| io_uring | Completion | Linux | ✅ |
| epoll | Readiness | Linux | ✅ |
| epoll (emulated) | Completion | Linux | ✅ |
| kqueue | Readiness | macOS | Planned |
| kqueue (emulated) | Completion | macOS | Planned |
| IOCP | Completion | Windows | - |
| IOCP (emulated) | Readiness | Windows | - |

---

## Install / build

```bash
uv sync                                                        # Install dev dependencies
uv run mojox check                                             # Type-check / compile bouclette
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
from bouclette import Backend, IOError, Socket, SocketAddrV4, WatchLoop
from bouclette.net.options import Backlog


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
---

## Project layout

```
bouclette/                           Public API — what developers import
├── watch/                           Completion model: WatchLoop + asyncio-style Futures
│   ├── loop.mojo                    WatchLoop (accept, connect, connect_with_timeout,
│   │                                recv, send, recv_msg, send_msg, recv_from, send_to,
│   │                                timeout, buffer_pool, recv_msg_multishot,
│   │                                datagram_sink, run, step)
│   ├── accept.mojo                  AcceptFuture
│   ├── connect.mojo                 ConnectFuture
│   ├── connect_timeout.mojo         ConnectWithTimeoutFuture (composite connect+timer)
│   ├── recv.mojo                    RecvFuture
│   ├── send.mojo                    SendFuture
│   ├── recv_msg.mojo                RecvMsgFuture
│   ├── send_msg.mojo                SendMsgFuture
│   ├── timer.mojo                   TimerFuture (cancel, reset)
│   ├── transfer.mojo                TransferResult, TransferFailed, MessageFailed, FailureReason
│   ├── outcome.mojo                 ConnectOutcome
│   ├── pool.mojo                    BufferPool, LeasedBuffer (loop-owned receive buffers)
│   ├── stream.mojo                  Datagram, DatagramStream (multishot recvmsg)
│   ├── sink.mojo                    DatagramSink (fire-and-forget batched send, sendmmsg)
│   ├── _shared.mojo                 Driver pointer, liveness and tally shared with slab states
│   ├── _callback.mojo               Internal future-state ownership hooks
│   ├── _message.mojo                Slab-owned msghdr state behind the message futures
│   └── _slab.mojo                   Per-kind chunked slab of operation states
├── readiness.mojo                   Readiness model: ReadinessLoop, ReadinessRegistry,
│                                    ReadinessHandler
├── proactor/                        Raw completion plumbing under watch/
│   ├── completion_loop.mojo         CompletionLoop — pointer-level escape hatch
│   ├── loop.mojo                    EventLoop — single-threaded completion-driven loop (enforced by the kernel on io_uring)
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
