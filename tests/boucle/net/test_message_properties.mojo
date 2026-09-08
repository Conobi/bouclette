"""Property checks over the control-record builder and its decoder.

`Message.append_control` encodes `(level, type, data)` triples into the
control area and `ControlMessages` decodes them. For random capacities
and record lists these checks assert that encode then decode is the
identity on every record that fit, that the first record that does not
fit raises EINVAL and leaves every byte and the appended length as they
were, that no byte past the appended length is ever written, and that
`control_space` is monotone and never below 16.

The generator is a deterministic 64-bit LCG seeded from a constant, so
a failure reproduces; the seed and state are printed when a property
fails. Run with `-D ASSERT=all` so the walker's own assertions are live.
"""

from std.testing import assert_equal, assert_true

from boucle.net import ControlMessages, Message
from boucle.socle.platform import EINVAL

comptime SEED: UInt64 = 0x2545F4914F6CDD1D
comptime ITERATIONS = 5000
comptime MAX_CAPACITY = 96
comptime MAX_DATA = 24
comptime MAX_RECORDS = 6
comptime CMSG_HDR = 16


# ===----------------------------------------------------------------------=== #
# Generator
# ===----------------------------------------------------------------------=== #


struct Lcg(Movable):
    """Knuth's MMIX linear congruential generator; the high 32 bits are the output."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def __init__(out self, *, deinit move: Self):
        self.state = move.state

    def next(mut self) -> UInt64:
        """Advance and return the high 32 bits, the well-mixed ones of an LCG."""
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return self.state >> 32

    def below(mut self, n: Int) -> Int:
        """A value in `0 ..< n`; `n` is at least 1."""
        return Int(self.next() % UInt64(n))

    def bytes(mut self, n: Int) -> List[UInt8]:
        """`n` random bytes."""
        var buf = List[UInt8](length=n, fill=0)
        for i in range(n):
            buf[i] = UInt8(self.next() & 0xFF)
        return buf^

    def i32(mut self) -> Int32:
        """A value in `-32768 ... 32767`."""
        return Int32(self.below(0x10000) - 0x8000)


# ===----------------------------------------------------------------------=== #
# Helpers
# ===----------------------------------------------------------------------=== #


def _snapshot(msg: Message) -> List[UInt8]:
    """Copy the whole control area."""
    var out = List[UInt8](length=msg.control_capacity(), fill=0)
    for i in range(msg.control_capacity()):
        out[i] = msg._control[i]
    return out^


def _same_bytes(a: List[UInt8], b: List[UInt8], lo: Int, hi: Int) -> Bool:
    """True when `a[lo:hi] == b[lo:hi]`."""
    for i in range(lo, hi):
        if a[i] != b[i]:
            return False
    return True


# ===----------------------------------------------------------------------=== #
# Properties
# ===----------------------------------------------------------------------=== #


def _one_round(mut rng: Lcg, iteration: Int) raises:
    """Random capacity, random records: encode until the first EINVAL, decode, compare."""
    var where = " at iteration " + String(iteration)
    var capacity = rng.below(MAX_CAPACITY + 1)
    var msg = Message(List[UInt8](), control_capacity=capacity)
    # Start from a dirty area, half the time one a receive "wrote".
    for i in range(capacity):
        msg._control[i] = UInt8(rng.next() & 0xFF)
    if rng.below(2) == 0:
        msg._set_control_received(rng.below(capacity + 1))
    var before = _snapshot(msg)

    var levels = List[Int32]()
    var types = List[Int32]()
    var datas = List[List[UInt8]]()
    var appended = 0
    var wanted = rng.below(MAX_RECORDS + 1)
    for _ in range(wanted):
        var data = rng.bytes(rng.below(MAX_DATA + 1))
        var level = rng.i32()
        var type = rng.i32()
        var space = Message.control_space(len(data))
        var fits = space <= capacity - appended
        var pre = _snapshot(msg)
        var ok = True
        var errno = 0
        try:
            msg.append_control(level, type, Span(data))
        except e:
            ok = False
            errno = e.errno_value()
        assert_true(
            ok == fits, "append succeeds exactly when the record fits" + where
        )
        assert_equal(
            msg._control_received, 0, "received length is 0 after any append" + where
        )
        if not ok:
            assert_equal(errno, EINVAL, "the failure is EINVAL" + where)
            assert_equal(
                msg._control_appended,
                appended,
                "failed append: appended length unchanged" + where,
            )
            assert_true(
                _same_bytes(msg._control, pre, 0, capacity),
                "failed append leaves the area byte-identical" + where,
            )
            break
        appended += space
        assert_equal(
            msg._control_appended, appended, "appended length grew by CMSG_SPACE" + where
        )
        assert_true(
            _same_bytes(msg._control, pre, appended, capacity),
            "no byte past the appended length changed" + where,
        )
        levels.append(level)
        types.append(type)
        datas.append(data^)

    if wanted == 0:
        return

    var n = 0
    for cm in msg.control():
        assert_true(n < len(levels), "the walker yields no extra record" + where)
        assert_equal(Int(cm.level), Int(levels[n]), "level" + where)
        assert_equal(Int(cm.type), Int(types[n]), "type" + where)
        assert_equal(len(cm.data()), len(datas[n]), "data length" + where)
        for i in range(len(cm.data())):
            assert_equal(Int(cm.data()[i]), Int(datas[n][i]), "data byte" + where)
        n += 1
    assert_equal(n, len(levels), "every appended record walks back" + where)
    assert_true(
        _same_bytes(msg._control, before, appended, capacity),
        "bytes past the appended length are what they were before the first append"
        + where,
    )


def property_append_then_walk_is_identity(mut rng: Lcg) raises:
    """Encode then decode yields the appended triples; overflow is inert."""
    for it in range(ITERATIONS):
        _one_round(rng, it)


def property_control_space_is_monotone_and_at_least_16(mut rng: Lcg) raises:
    """`control_space` never drops below 16, never decreases, and matches CMSG_SPACE."""
    for it in range(ITERATIONS):
        var n = rng.below(4096) - 64
        var here = Message.control_space(n)
        var next = Message.control_space(n + 1)
        assert_true(here >= CMSG_HDR, "at least a header at " + String(it))
        assert_true(next >= here, "monotone at " + String(it))
        if n >= 0:
            assert_equal(
                here, ((CMSG_HDR + n + 7) // 8) * 8, "CMSG_SPACE at " + String(it)
            )
        else:
            assert_equal(here, CMSG_HDR, "negative is 0 at " + String(it))


# ===----------------------------------------------------------------------=== #
# main
# ===----------------------------------------------------------------------=== #


def _run_all(mut rng: Lcg) raises:
    """Run every property, in order, on one generator."""
    property_append_then_walk_is_identity(rng)
    property_control_space_is_monotone_and_at_least_16(rng)


def main() raises:
    var rng = Lcg(SEED)
    try:
        _run_all(rng)
    except e:
        print(
            "FAIL: test_message_properties.mojo seed=",
            hex(SEED),
            "state=",
            hex(rng.state),
        )
        raise e
    print(
        "PASS: test_message_properties.mojo (",
        ITERATIONS,
        "iterations per property)",
    )
