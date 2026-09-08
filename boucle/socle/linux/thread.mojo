"""Pthread synchronisation primitives via external_call.

`_Mutex` and `_Condvar` wrap pthread_mutex_t and pthread_cond_t. Both are
heap-allocated as opaque byte arrays sized per architecture.
"""

from std.ffi import external_call
from std.memory import Pointer, unsafe_memset
from std.memory.alloc import unsafe_alloc
from boucle.socle.ptr import null_ptr
from boucle.socle.linux.raw import (
    PTHREAD_MUTEX_SIZE,
    PTHREAD_COND_SIZE,
    PTHREAD_T_SIZE,
    SIG_SETMASK,
    SIGSET_SIZE,
)


# ── Mutex ────────────────────────────────────────────────────────────────


struct _Mutex(Movable):
    """POSIX mutex via external_call to pthread_mutex_*."""

    var _raw: Pointer[UInt8, MutUntrackedOrigin]

    def __init__(out self) raises:
        """Allocate and initialise a default-attribute mutex."""
        self._raw = unsafe_alloc[UInt8](PTHREAD_MUTEX_SIZE)
        unsafe_memset(self._raw, 0, PTHREAD_MUTEX_SIZE)
        var res = external_call["pthread_mutex_init", Int32](
            self._raw,
            null_ptr[NoneType, MutUntrackedOrigin](),
        )
        if res != 0:
            self._raw.unsafe_free()
            raise "pthread_mutex_init failed: " + String(res)

    def __init__(out self, *, deinit move: Self):
        self._raw = move._raw

    def lock(mut self):
        """Acquire the mutex. Blocks until available."""
        var res = external_call["pthread_mutex_lock", Int32](self._raw)
        debug_assert(res == 0, "pthread_mutex_lock failed")

    def unlock(mut self):
        """Release the mutex."""
        var res = external_call["pthread_mutex_unlock", Int32](self._raw)
        debug_assert(res == 0, "pthread_mutex_unlock failed")

    def __deinit__(deinit self):
        """Destroy the mutex and free its backing memory."""
        _ = external_call["pthread_mutex_destroy", Int32](self._raw)
        self._raw.unsafe_free()


# ── Condvar ──────────────────────────────────────────────────────────────


struct _Condvar(Movable):
    """POSIX condition variable via external_call to pthread_cond_*."""

    var _raw: Pointer[UInt8, MutUntrackedOrigin]

    def __init__(out self) raises:
        """Allocate and initialise a default-attribute condvar."""
        self._raw = unsafe_alloc[UInt8](PTHREAD_COND_SIZE)
        unsafe_memset(self._raw, 0, PTHREAD_COND_SIZE)
        var res = external_call["pthread_cond_init", Int32](
            self._raw,
            null_ptr[NoneType, MutUntrackedOrigin](),
        )
        if res != 0:
            self._raw.unsafe_free()
            raise "pthread_cond_init failed: " + String(res)

    def __init__(out self, *, deinit move: Self):
        self._raw = move._raw

    def wait(mut self, ref mutex: _Mutex):
        """Block until signalled. `mutex` must be held; released during wait."""
        var res = external_call["pthread_cond_wait", Int32](
            self._raw, mutex._raw
        )
        debug_assert(res == 0, "pthread_cond_wait failed")

    def signal(mut self):
        """Wake one waiting thread."""
        var res = external_call["pthread_cond_signal", Int32](self._raw)
        debug_assert(res == 0, "pthread_cond_signal failed")

    def broadcast(mut self):
        """Wake all waiting threads."""
        var res = external_call["pthread_cond_broadcast", Int32](self._raw)
        debug_assert(res == 0, "pthread_cond_broadcast failed")

    def __deinit__(deinit self):
        """Destroy the condvar and free its backing memory."""
        _ = external_call["pthread_cond_destroy", Int32](self._raw)
        self._raw.unsafe_free()


# ── Thread ───────────────────────────────────────────────────────────────

comptime _PthreadEntryFn = def (
    Pointer[NoneType, MutUntrackedOrigin],
) thin -> Pointer[NoneType, MutUntrackedOrigin]


struct _Thread(Movable):
    """OS thread via pthread_create. Detachable."""

    var _handle: Pointer[UInt8, MutUntrackedOrigin]
    var _detached: Bool

    def __init__(
        out self,
        *,
        entry: _PthreadEntryFn,
        context: Pointer[NoneType, MutUntrackedOrigin],
    ) raises:
        """Spawn a new thread. Masks all deliverable signals first."""
        self._handle = unsafe_alloc[UInt8](PTHREAD_T_SIZE)
        unsafe_memset(self._handle, 0, PTHREAD_T_SIZE)
        self._detached = False

        # Mask all signals in the calling thread before spawn so the
        # child inherits the mask, then restore. `pthread_sigmask` is a
        # glibc symbol expecting the full 128-byte `sigset_t`, not the
        # kernel's 8-byte word; an undersized buffer here makes glibc
        # read and write past it on every thread spawn.
        var full = unsafe_alloc[UInt8](SIGSET_SIZE)
        unsafe_memset(full, 0xFF, SIGSET_SIZE)
        var old_set = unsafe_alloc[UInt8](SIGSET_SIZE)
        _ = external_call["pthread_sigmask", Int32](
            Int32(SIG_SETMASK),
            full,
            old_set,
        )

        # Extract the fn address for pthread_create.
        var fn_addr = Int(Pointer(to=entry).unsafe_bitcast[Int]()[])
        var fn_ptr = Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=fn_addr
        )
        var res = external_call["pthread_create", Int32](
            self._handle,
            null_ptr[NoneType, MutUntrackedOrigin](),
            fn_ptr,
            context,
        )

        # Restore the caller's signal mask.
        _ = external_call["pthread_sigmask", Int32](
            Int32(SIG_SETMASK),
            old_set,
            null_ptr[UInt8, MutUntrackedOrigin](),
        )
        full.unsafe_free()
        old_set.unsafe_free()

        if res != 0:
            self._handle.unsafe_free()
            raise "pthread_create failed: " + String(res)

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self._detached = move._detached

    def detach(mut self):
        """Detach the thread. It will clean up on exit."""
        if not self._detached:
            var handle_val = self._handle.unsafe_bitcast[UInt64]()[]
            _ = external_call["pthread_detach", Int32](handle_val)
            self._detached = True

    def __deinit__(deinit self):
        """Detach if not already detached, then free the handle buffer."""
        if not self._detached:
            var handle_val = self._handle.unsafe_bitcast[UInt64]()[]
            _ = external_call["pthread_detach", Int32](handle_val)
        self._handle.unsafe_free()
