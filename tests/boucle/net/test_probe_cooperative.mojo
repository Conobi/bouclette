"""Test that ProbeBatch cooperatively services other I/O on the same loop."""

from std.memory import Pointer
from std.testing import assert_true

from boucle.net.probe import ProbeBatch, PortStatus
from boucle.net.addr import SocketAddrV4
from boucle.proactor.completion import Completion
from boucle.completion import CompletionLoop


struct CoopTracker:
    """Tracks whether a secondary NOP fires during batch execution."""

    var nop_fired: Bool
    var cmp: Completion

    def __init__(out self):
        """Construct a CoopTracker with nop_fired=False and a default Completion."""
        self.nop_fired = False
        self.cmp = Completion()

    def wire(mut self):
        """Wire the Completion callback to point at this tracker instance."""
        self.cmp.context = Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=self))
        )
        self.cmp.invoke = Self._on_nop

    @staticmethod
    def _on_nop(
        ctx: Pointer[NoneType, MutUntrackedOrigin], result: Int, flags: UInt32
    ):
        """Completion callback that sets nop_fired=True on the owning tracker."""
        var self_ptr = Pointer[CoopTracker, MutUntrackedOrigin](
            unsafe_from_address=Int(ctx)
        )
        self_ptr[].nop_fired = True


def test_probe_cooperative() raises:
    var loop = CompletionLoop(sq_entries=256)

    # Submit a secondary NOP BEFORE starting the batch.
    var tracker = CoopTracker()
    tracker.wire()
    loop.submit_nop(
        Pointer[Completion, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=tracker.cmp))
        )
    )

    # Run a batch of 3 refused ports.
    var ports = List[Int]()
    ports.append(1)
    ports.append(2)
    ports.append(3)

    var batch = ProbeBatch(
        target=SocketAddrV4(127, 0, 0, 1, port=0),
        ports=ports^,
        timeout_ms=2000,
        concurrency=3,
    )
    batch.run_cooperative(loop)

    # The NOP should have fired during the batch's cooperative polling.
    assert_true(tracker.nop_fired)


def main() raises:
    test_probe_cooperative()
    print("PASS: test_probe_cooperative.mojo")
