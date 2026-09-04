"""Stackful coroutine example: yield/resume between caller and coroutine.

Demonstrates the Coroutine / Yielder API. The coroutine runs on its
own stack and suspends via `y.suspend()`; the caller drives it
forward with `coro.resume()`. Real yield/resume semantics, no state
machine transform.

Coroutine is a linear type (@explicit_destroy) -- the caller must call
`close()` on every path, including error paths. The try/except below
ensures the handle is always closed before any exception propagates.

Run:
    uv run -- mojo run -I . -D ASSERT=all examples/coro_echo.mojo
"""

from boucle.coroutine import Coroutine, Yielder
from std.testing import assert_true


struct Unit(Movable, Deinitable):
    """Trivial state for coroutines that carry no shared data."""

    def __init__(out self):
        """Initialize a Unit value."""
        pass

    def __init__(out self, *, deinit move: Self):
        """Move constructor for Unit."""
        pass


def _echo_body(mut y: Yielder[Unit]) raises:
    """Body that prints, suspends, then prints again."""
    print("in coro")
    y.suspend()
    print("resumed")


def main() raises:
    """Drive a coroutine through its full lifecycle."""
    var coro = Coroutine[Unit](_echo_body, Unit())
    try:
        print("before resume")
        coro.resume()
        print("after first resume")
        coro.resume()
        print("done")
    except e:
        coro^.close()
        raise e^

    var done = coro.is_done()
    coro^.close()
    assert_true(done)

    print("OK")
