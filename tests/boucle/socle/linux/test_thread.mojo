"""Test `_Mutex`, `_Condvar`, and `_Thread` basic operations."""

from std.testing import assert_true
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.ffi import external_call
from boucle.socle.linux.thread import _Mutex, _Condvar, _Thread
from boucle.socle.ptr import null_ptr


def test_mutex_lock_unlock() raises:
    """A mutex can be locked and unlocked without deadlock."""
    var m = _Mutex()
    m.lock()
    m.unlock()
    # Second lock/unlock to verify reuse.
    m.lock()
    m.unlock()


def test_condvar_signal() raises:
    """A condvar can be created and destroyed."""
    var cv = _Condvar()
    # signal on a condvar with no waiters is a no-op.
    cv.signal()
    cv.broadcast()


def _test_entry(
    arg: Pointer[NoneType, MutUntrackedOrigin],
) -> Pointer[NoneType, MutUntrackedOrigin]:
    """Write 99 to the shared Int."""
    var int_ptr = arg.unsafe_bitcast[Int]()
    int_ptr[] = 99
    return null_ptr[NoneType, MutUntrackedOrigin]()


def test_thread_create_and_detach() raises:
    """A thread runs to completion after detach."""
    var shared = unsafe_alloc[Int](1)
    shared[] = 0
    var ctx = Pointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(shared)
    )
    var t = _Thread(entry=_test_entry, context=ctx)
    t.detach()
    # Brief sleep to let the detached thread finish.
    _ = external_call["usleep", Int32](Int32(50_000))  # 50ms
    assert_true(shared[] == 99, "detached thread did not run")
    shared.unsafe_free()


def main() raises:
    test_mutex_lock_unlock()
    print("PASS: mutex lock/unlock")
    test_condvar_signal()
    print("PASS: condvar signal/broadcast")
    test_thread_create_and_detach()
    print("PASS: thread create and detach")
