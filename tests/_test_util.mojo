"""Shared test helpers."""

from std.ffi import external_call
from std.memory.alloc import unsafe_alloc
from std.os import getenv, listdir, remove, rmdir
from std.os.path import isdir, islink


def _remove_tree(path: String):
    """Best-effort recursive delete; symlinks are unlinked, never followed."""
    try:
        if isdir(path) and not islink(path):
            for name in listdir(path):
                _remove_tree(path + "/" + name)
            rmdir(path)
        else:
            remove(path)
    except:
        pass


struct TempDir(Movable):
    """Private scratch directory, deleted recursively when the value dies.

    Made with `mkdtemp(3)` under `$TMPDIR` (else `/tmp`): unique, mode 0700 and
    owned by the caller, so no other user can pre-create or symlink-redirect its
    entries (CWE-377). Hold one per test as a local and end the test with
    `_ = td^`: Mojo destroys locals after their last use, so without it the
    directory could vanish early. It is also removed when the test raises.
    """

    var dir: String

    def __init__(out self) raises:
        var base = getenv("TMPDIR", "/tmp")
        while base.byte_length() > 1 and base.endswith("/"):
            var shorter = String(base[byte=: base.byte_length() - 1])
            base = shorter^
        var template = base + "/bouclette-test-XXXXXX"
        var tb = template.as_bytes()
        var buf = unsafe_alloc[UInt8](len(tb) + 1)
        for i in range(len(tb)):
            buf[unsafe_offset=i] = tb[i]
        buf[unsafe_offset=len(tb)] = 0  # mkdtemp needs a NUL terminator
        var rc = external_call["mkdtemp", Int](buf)
        if rc == 0:
            buf.unsafe_free()
            raise "mkdtemp failed for " + template
        var out = List[UInt8]()
        var j = 0
        while buf[unsafe_offset=j] != 0:
            out.append(buf[unsafe_offset=j])
            j += 1
        buf.unsafe_free()
        self.dir = String(from_utf8_lossy=out)

    def __deinit__(deinit self):
        _remove_tree(self.dir)

    def path(self, name: String) -> String:
        """Path of `name` inside the directory; the file is not created."""
        return self.dir + "/" + name

    def cpath(self, name: String) -> List[UInt8]:
        """Like `path`, as NUL-terminated bytes for passing to libc `open(2)`.

        A Mojo `String` is not guaranteed a trailing NUL once built by
        concatenation, so `String.unsafe_ptr()` is unsafe as a C string.
        """
        var out = List[UInt8]()
        out.extend(self.path(name).as_bytes())
        out.append(0)
        return out^
