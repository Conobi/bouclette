from boucle.handle import RawHandle, OwnedHandle
from std.testing import assert_true
from std.ffi import external_call


def main() raises:
    # Dup stdin to get a valid fd (using external_call directly to avoid
    # a Mojo 0.26.2 mojopkg crash when importing from multiple submodules).
    var raw = external_call["dup", Int32](Int32(0))
    assert_true(raw > -1)

    var handle = OwnedHandle(raw=raw)
    assert_true(handle.raw() > -1)

    # Move semantics: transfer ownership from handle to handle2.
    # handle is consumed; handle2 owns the fd and will auto-close on drop.
    var handle2 = handle^
    assert_true(handle2.raw() > -1)

    # OwnedHandle.__init__ raises on negative raw handle
    var caught_neg = False
    try:
        _ = OwnedHandle(raw=Int32(-1))
    except:
        caught_neg = True
    assert_true(caught_neg)

    # handle2 goes out of scope here and __del__ closes the fd automatically.
    print("All handle tests passed.")
