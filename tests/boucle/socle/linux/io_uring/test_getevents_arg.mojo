"""Golden layout of io_uring_getevents_arg and a live bounded wait.

struct io_uring_getevents_arg { __u64 sigmask; __u32 sigmask_sz; __u32 pad;
__u64 ts; } is 24 bytes. With IORING_ENTER_EXT_ARG the kernel reads it
from the enter call's `argp`/`argsz` and returns -ETIME when the wait
expires before any completion arrives.
"""

from std.memory import Pointer
from std.sys.info import size_of
from std.testing import assert_equal, assert_true

from boucle.socle.linux.errno import Errno
from boucle.socle.linux.io_uring import (
    EnterArg,
    IoUring,
    IoUringEnterFlags,
    IoUringFeatureFlags,
    IoUringGetEventsArg,
    IoUringParams,
)
from boucle.socle.linux.raw import ETIME, __kernel_timespec
from boucle.socle.linux.raw.ctypes import c_void
from std.time import perf_counter_ns


def _has_io_uring() -> Bool:
    """Probe whether io_uring syscalls are available on this kernel."""
    try:
        var ring = IoUring[](sq_entries=4)
        ring^.__deinit__()
        return True
    except:
        return False


def test_getevents_arg_layout() raises:
    """Size, field offsets and zero defaults match the kernel UAPI."""
    assert_equal(size_of[IoUringGetEventsArg](), 24)
    var arg = IoUringGetEventsArg()
    assert_equal(Int(arg.sigmask), 0)
    assert_equal(Int(arg.sigmask_sz), 0)
    assert_equal(Int(arg.pad), 0)
    assert_equal(Int(arg.ts), 0)
    var base = Int(Pointer(to=arg))
    assert_equal(Int(Pointer(to=arg.sigmask)) - base, 0)
    assert_equal(Int(Pointer(to=arg.sigmask_sz)) - base, 8)
    assert_equal(Int(Pointer(to=arg.pad)) - base, 12)
    assert_equal(Int(Pointer(to=arg.ts)) - base, 16)


def test_live_bounded_wait_times_out() raises:
    """An idle ring waited on with a 30 ms argument raises -ETIME after 30 ms."""
    var params = IoUringParams()
    var ring = IoUring[](sq_entries=UInt32(4), params=params)
    if not Bool(params.features & IoUringFeatureFlags.EXT_ARG):
        print("  SKIP: kernel lacks IORING_FEAT_EXT_ARG")
        ring^.__deinit__()
        return
    var ts = __kernel_timespec(tv_sec=Int64(0), tv_nsec=Int64(30_000_000))
    var arg = IoUringGetEventsArg()
    arg.ts = UInt64(Int(Pointer(to=ts)))
    var arg_p = Pointer(to=arg)
    var enter_arg = EnterArg[24, IoUringEnterFlags.EXT_ARG, ImmStaticOrigin](
        arg_unsafe_ptr=Pointer[c_void, ImmStaticOrigin](
            unsafe_from_address=Int(arg_p)
        )
    )
    var start = perf_counter_ns()
    var timed_out = False
    try:
        _ = ring.submit_and_wait(wait_nr=UInt32(1), arg=enter_arg)
    except e:
        timed_out = Errno(error=e) is Errno(errno=UInt16(ETIME))
    var elapsed_ms = (perf_counter_ns() - start) // 1_000_000
    assert_true(timed_out, "expected -ETIME from the bounded wait")
    assert_true(elapsed_ms >= 30, "returned early: " + String(elapsed_ms))
    assert_true(elapsed_ms < 500, "returned late: " + String(elapsed_ms))
    _ = ts
    _ = arg
    ring^.__deinit__()


def main() raises:
    test_getevents_arg_layout()
    if _has_io_uring():
        test_live_bounded_wait_times_out()
    else:
        print("SKIP: io_uring not available for the live wait")
    print("PASS: test_getevents_arg.mojo")
