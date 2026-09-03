"""ConnectFuture — async connect via WatchLoop.

_ConnectFutureState holds the per-operation Completion token, a copy of
the target address storage (for pointer stability), and the raw CQE
result. ConnectFuture is the RAII handle returned to callers — it owns
the heap-allocated state and decodes the result into a ConnectOutcome.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

from boucle.net.addr import SocketAddrStorV4
from boucle.proactor.completion import Completion
from boucle.watch._callback import _FutureCallback, _dispatch
from boucle.watch.outcome import ConnectOutcome


# ===----------------------------------------------------------------------=== #
# _ConnectFutureState — internal, heap-allocated per-operation state
# ===----------------------------------------------------------------------=== #


struct _ConnectFutureState(_FutureCallback):
    """Internal state for a single async connect operation.

    Implements _FutureCallback so the generic _dispatch can deliver
    CQE results into this struct. Stored on the heap; the Completion's
    context pointer points back to the enclosing _ConnectFutureState.

    The address storage is copied into this struct so that the pointer
    passed to io_uring remains valid until the CQE fires, regardless of
    the caller's stack lifetime.

    Fields:
        completion: The io_uring completion token (fn ptr + context ptr).
        _addr_stor: Copy of the target address for pointer stability.
        _cqe_result: Raw CQE result (0 on success, negative errno on failure).
        done: True once the CQE callback has fired.
        consumed: True once result() has been called.
    """

    var completion: Completion
    var _addr_stor: SocketAddrStorV4
    var _cqe_result: Int
    var done: Bool
    var consumed: Bool

    def __init__(out self, addr_stor: SocketAddrStorV4):
        """Construct a _ConnectFutureState with address storage.

        The completion is initialized with a no-op callback; the caller
        must wire invoke and context after heap allocation.

        Args:
            addr_stor: Copy of the target sockaddr_in for pointer stability.
        """
        self.completion = Completion()
        self._addr_stor = addr_stor
        self._cqe_result = 0
        self.done = False
        self.consumed = False

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source state to move from.
        """
        self.completion = move.completion^
        self._addr_stor = move._addr_stor
        self._cqe_result = move._cqe_result
        self.done = move.done
        self.consumed = move.consumed

    def set_result(mut self, result: Int):
        """Store the raw CQE result from io_uring connect.

        Does not decode the result — ConnectFuture.result() handles that
        via ConnectOutcome.from_cqe_result().

        Args:
            result: The io_uring CQE result (0 on success, negative errno
                    on failure).
        """
        self._cqe_result = result
        self.done = True


# ===----------------------------------------------------------------------=== #
# ConnectFuture — RAII handle returned to callers
# ===----------------------------------------------------------------------=== #


struct ConnectFuture(Movable):
    """RAII handle for an in-flight async connect operation.

    Owns a heap-allocated _ConnectFutureState. Call done() to check
    completion, then result() to extract the ConnectOutcome.

    Unlike AcceptFuture, no fd cleanup is needed on drop — connect does
    not produce a new fd; it modifies the existing socket in place.
    """

    var _state: Pointer[_ConnectFutureState, MutUntrackedOrigin]

    def __init__(
        out self,
        state: Pointer[_ConnectFutureState, MutUntrackedOrigin],
    ):
        """Construct a ConnectFuture wrapping a heap-allocated state.

        Args:
            state: Pointer to the heap-allocated _ConnectFutureState.
        """
        self._state = state

    def __init__(out self, *, deinit move: Self):
        """Move constructor — transfers ownership of the state pointer.

        Args:
            move: The source ConnectFuture to move from.
        """
        self._state = move._state

    def __deinit__(deinit self):
        """Release the heap-allocated state.

        No fd cleanup needed — connect does not produce a new fd.
        """
        self._state.unsafe_deinit_pointee()
        self._state.unsafe_free()

    def result(mut self) raises -> ConnectOutcome:
        """Decode the CQE result into a ConnectOutcome.

        Consumes the result — a second call raises. Does NOT raise on
        REFUSED/TIMEOUT — those are valid ConnectOutcome variants. Only
        raises if the result was already consumed or the operation has
        not completed.

        Returns:
            A ConnectOutcome discriminating CONNECTED, REFUSED, TIMEOUT,
            NETWORK_UNREACHABLE, or ERROR.

        Raises:
            If the result was already consumed or the operation has not
            completed.
        """
        if self._state[].consumed:
            raise "result already consumed"
        if not self._state[].done:
            raise "operation not complete"
        self._state[].consumed = True
        return ConnectOutcome.from_cqe_result(self._state[]._cqe_result)

    def done(self) -> Bool:
        """Return True if the connect operation has completed.

        Returns:
            True once the CQE callback has fired (success or failure).
        """
        return self._state[].done
