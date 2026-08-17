"""Stackful coroutine example: yield/resume between caller and coroutine.

Demonstrates the Coroutine / Yielder API. The coroutine runs on its
own stack and suspends via `y.yield_to_caller()`; the caller drives it
forward with `coro.resume()`. Real yield/resume semantics, no state
machine transform.

Coroutine is a linear type (@explicit_destroy) -- the caller must call
`destroy()` on every path, including error paths. The try/except below
ensures the handle is always destroyed before any exception propagates.

Run:
    uv run -- mojo run -I . -D ASSERT=all examples/coro_echo.mojo
"""

from boucle.coroutine import Coroutine as CoroHandle, Yielder as CoroYielder
from std.testing import assert_true


def _echo_body(mut y: CoroYielder) raises:
    print("in coro")
    y.yield_to_caller()
    print("resumed")


def main() raises:
    var coro = CoroHandle(_echo_body)
    try:
        print("before resume")
        coro.resume()
        print("after first resume")
        coro.resume()
        print("done")
    except e:
        coro^.destroy()
        raise e^

    var done = coro.is_done()
    coro^.destroy()
    assert_true(done)

    print("OK")
