"""`_TimerHeap` against a sorted-list model under 5000 random push, update, remove and pop operations.

An inline LCG drives the sequence. After every operation the heap order
holds, `_pos` names every entry's heap index and nothing else, and the
minimum deadline equals the model's. Deadlines are unique (random high
bits plus the pool index) so the model's minimum is the only valid
answer. `update` and `remove_by_pool_index` on an unarmed index return
False.
"""

from std.testing import assert_equal, assert_true

from boucle.drivers.epoll_completion import _TimerEntry, _TimerHeap

comptime ITERATIONS = 5000
comptime MAX_POOL_INDEX = 4096


struct Lcg:
    """Knuth's 64-bit LCG; the high 31 bits are returned."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> UInt64:
        """Advance and return the next value."""
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return self.state >> 33

    def below(mut self, n: Int) -> Int:
        """Return a value in `0..n-1`; `n` must be positive."""
        return Int(self.next() % UInt64(n))


struct Model:
    """Armed timers kept sorted by deadline, the oracle for the heap."""

    var entries: List[_TimerEntry]

    def __init__(out self):
        self.entries = List[_TimerEntry]()

    def insert(mut self, entry: _TimerEntry):
        """Insert keeping the list sorted by deadline."""
        var i = 0
        while i < len(self.entries) and self.entries[i].deadline_ns < entry.deadline_ns:
            i += 1
        self.entries.insert(i, entry)

    def remove(mut self, pool_index: Int):
        """Remove the entry armed at `pool_index`; it must exist."""
        for i in range(len(self.entries)):
            if self.entries[i].pool_index == pool_index:
                _ = self.entries.pop(i)
                return
        debug_assert(False, "model has no entry for pool index")

    def pop_min(mut self) -> _TimerEntry:
        """Remove and return the earliest entry."""
        return self.entries.pop(0)


def _deadline(mut rng: Lcg, pool_index: Int) -> Int64:
    """A deadline unique to `pool_index` among all draws."""
    return Int64(rng.below(1_000_000)) * Int64(MAX_POOL_INDEX) + Int64(pool_index)


def _check(heap: _TimerHeap, model: Model) raises:
    """Heap order, position table and minimum all agree with the model."""
    assert_equal(len(heap._entries), len(model.entries), "size")
    for i in range(len(heap._entries)):
        if i > 0:
            var parent = (i - 1) // 2
            assert_true(
                heap._entries[parent].deadline_ns <= heap._entries[i].deadline_ns,
                "heap order broken at " + String(i),
            )
        assert_equal(
            heap.position(heap._entries[i].pool_index), i, "position table"
        )
    var armed = 0
    for p in range(len(heap._pos)):
        if heap._pos[p] >= 0:
            armed += 1
            assert_equal(heap._entries[heap._pos[p]].pool_index, p, "pos points back")
    assert_equal(armed, len(model.entries), "no stale positions")
    if len(model.entries) > 0:
        assert_equal(heap.peek_deadline(), model.entries[0].deadline_ns, "minimum")
    else:
        assert_equal(heap.peek_deadline(), Int64.MAX)


def test_random_operations_match_model() raises:
    """5000 random operations, checked after each one."""
    var rng = Lcg(0x9E3779B97F4A7C15)
    var heap = _TimerHeap()
    var model = Model()
    var free = List[Int]()
    for i in range(MAX_POOL_INDEX):
        free.append(i)
    var armed = List[Int]()

    for _ in range(ITERATIONS):
        var op = rng.below(4)
        if op == 0 or len(armed) == 0:
            if len(free) == 0:
                continue
            var pi = free.pop(rng.below(len(free)))
            var entry = _TimerEntry(deadline_ns=_deadline(rng, pi), pool_index=pi)
            heap.push(entry)
            model.insert(entry)
            armed.append(pi)
        elif op == 1:
            var pi = armed[rng.below(len(armed))]
            var deadline = _deadline(rng, pi)
            assert_true(heap.update(pi, deadline), "update of an armed index")
            model.remove(pi)
            model.insert(_TimerEntry(deadline_ns=deadline, pool_index=pi))
        elif op == 2:
            var k = rng.below(len(armed))
            var pi = armed[k]
            armed[k] = armed[len(armed) - 1]
            _ = armed.pop()
            assert_true(heap.remove_by_pool_index(pi), "remove of an armed index")
            model.remove(pi)
            free.append(pi)
        else:
            var got = heap.pop()
            var want = model.pop_min()
            assert_equal(got.deadline_ns, want.deadline_ns, "pop deadline")
            assert_equal(got.pool_index, want.pool_index, "pop pool index")
            for k in range(len(armed)):
                if armed[k] == got.pool_index:
                    armed[k] = armed[len(armed) - 1]
                    _ = armed.pop()
                    break
            free.append(got.pool_index)
        _check(heap, model)

    # Drain: every pop matches the model until both are empty.
    while len(model.entries) > 0:
        var got = heap.pop()
        var want = model.pop_min()
        assert_equal(got.pool_index, want.pool_index, "drain order")
        _check(heap, model)
    assert_equal(len(heap._entries), 0)


def test_unarmed_index_is_refused() raises:
    """`update` and `remove_by_pool_index` on an index never pushed return False."""
    var heap = _TimerHeap()
    assert_true(not heap.update(3, Int64(10)))
    assert_true(not heap.remove_by_pool_index(3))
    heap.push(_TimerEntry(deadline_ns=Int64(5), pool_index=3))
    assert_true(not heap.update(4, Int64(10)), "index past the table")
    assert_true(heap.update(3, Int64(1)))
    assert_equal(heap.peek_deadline(), Int64(1))
    assert_true(heap.remove_by_pool_index(3))
    assert_true(not heap.remove_by_pool_index(3), "already removed")
    assert_equal(heap.position(3), -1)


def main() raises:
    test_random_operations_match_model()
    print("ok: random operations match model")
    test_unarmed_index_is_refused()
    print("ok: unarmed index is refused")
    print("PASS: test_timer_heap.mojo")
