"""ProbeBatch — cooperative batch port scanning with concurrency control.

Orchestrates multiple ConnectProbe instances in batches, respecting a
concurrency limit. Ensures no FD leaks by draining all in-flight probes
before destruction, even on exception paths.
"""

from std.memory import UnsafePointer
from std.memory.unsafe_pointer import alloc
from boucle.net.addr import SocketAddrV4
from boucle.net.probe import (
    PortStatus,
    ProbeResult,
    BatchSpec,
    compute_batches,
)
from boucle.net.connect_probe import ConnectProbe
from boucle.completion import CompletionLoop


struct ProbeBatch:
    """Cooperative batch scanner with concurrency control and FD-leak safety.

    Probes a list of ports on a single target, at most `concurrency` ports
    at a time. Uses ConnectProbe state machines with the deferred-cancel
    pattern. Results are sorted by port ascending after completion.

    Attributes:
        _target: The IPv4 address to probe (port field ignored; overridden per probe).
        _ports: The list of ports to scan.
        _timeout_ms: Per-probe timeout in milliseconds.
        _concurrency: Maximum number of concurrent probes per batch.
        _results: Accumulated probe results, sorted by port after run_cooperative.
    """

    var _target: SocketAddrV4
    var _ports: List[Int]
    var _timeout_ms: Int
    var _concurrency: Int
    var _results: List[ProbeResult]

    def __init__(
        out self,
        *,
        target: SocketAddrV4,
        var ports: List[Int],
        timeout_ms: Int,
        concurrency: Int,
    ) raises:
        """Construct a ProbeBatch for a target and port list.

        Validates that all ports are in [1, 65535] and concurrency >= 1.

        Args:
            target: The IPv4 address to probe (port field is overridden per probe).
            ports: List of TCP port numbers to scan.
            timeout_ms: Per-probe timeout in milliseconds.
            concurrency: Maximum number of concurrent probes.

        Raises:
            If any port is out of range or concurrency < 1.
        """
        for i in range(len(ports)):
            if ports[i] < 1 or ports[i] > 65535:
                raise "port out of range [1, 65535]"
        if concurrency < 1:
            raise "concurrency must be >= 1"
        self._target = target
        self._ports = ports^
        self._timeout_ms = timeout_ms
        self._concurrency = concurrency
        self._results = List[ProbeResult]()

    def run_cooperative(mut self, mut loop: CompletionLoop) raises:
        """Execute the batch scan cooperatively on the given completion loop.

        Processes ports in concurrency-limited batches. Each batch:
        1. Allocates ConnectProbe instances on the heap for pointer stability.
        2. Wires context and submits connect+timeout SQEs.
        3. Polls until all probes in the batch are done (deferred cancel pattern).
        4. Collects results and destroys probes (closing sockets via RAII).

        On exception, drains all in-flight probes before re-raising to prevent
        FD leaks.

        After all batches complete, results are sorted by port ascending.

        Args:
            loop: The opaque CompletionLoop.

        Raises:
            If submission fails (after draining in-flight probes).
        """
        if len(self._ports) == 0:
            return

        var batches = compute_batches(
            total=len(self._ports), concurrency=self._concurrency
        )

        for batch_idx in range(len(batches)):
            var batch_size = batches[batch_idx].size
            var offset = batches[batch_idx].offset

            # Heap-allocate probes for pointer stability (wire_context takes address).
            var probes = alloc[ConnectProbe](batch_size).as_unsafe_any_origin()

            # Initialize all probes (track count for cleanup on failure).
            var initialized = 0
            try:
                for i in range(batch_size):
                    var port_idx = offset + i
                    var target = SocketAddrV4(
                        self._target.ip.octets[0],
                        self._target.ip.octets[1],
                        self._target.ip.octets[2],
                        self._target.ip.octets[3],
                        port=UInt16(self._ports[port_idx]),
                    )
                    (probes + i).init_pointee_move(
                        ConnectProbe(target=target, timeout_ms=self._timeout_ms)
                    )
                    initialized += 1
            except e:
                for j in range(initialized):
                    (probes + j).destroy_pointee()
                probes.free()
                raise e^

            # Wire context (sets up callback pointers to each probe).
            for i in range(batch_size):
                (probes + i)[].wire_context()

            # Submit all probes in this batch (track count for drain on failure).
            var submitted = 0
            try:
                for i in range(batch_size):
                    (probes + i)[].submit(loop)
                    submitted += 1
            except e:
                if submitted > 0:
                    Self._drain_batch(probes, submitted, loop)
                for i in range(batch_size):
                    (probes + i).destroy_pointee()
                probes.free()
                raise e^

            # Cooperative poll loop with deferred cancel pattern.
            try:
                while not Self._all_done(probes, batch_size):
                    loop.run_once()
                    for i in range(batch_size):
                        (probes + i)[].flush_cancel(loop)
            except e:
                # Drain all in-flight probes before re-raising.
                Self._drain_batch(probes, batch_size, loop)
                for i in range(batch_size):
                    (probes + i).destroy_pointee()
                probes.free()
                raise e^

            # Collect results from completed probes.
            for i in range(batch_size):
                debug_assert(
                    (probes + i)[].result_is_set(), "result not set at collection"
                )
                var port_idx = offset + i
                self._results.append(
                    ProbeResult(
                        port=self._ports[port_idx],
                        status=(probes + i)[].result_status(),
                    )
                )

            # Destroy probes (Socket RAII closes FDs).
            for i in range(batch_size):
                (probes + i).destroy_pointee()
            probes.free()

        # Sort results by port ascending (insertion sort — small N).
        Self._sort_results(self._results)

    def results(ref self) -> ref [self._results] List[ProbeResult]:
        """Return a reference to the accumulated probe results, sorted by port ascending.

        Returns:
            A reference to the list of ProbeResult values in port order.
        """
        return self._results

    @staticmethod
    def _all_done(
        probes: UnsafePointer[ConnectProbe, MutAnyOrigin], count: Int
    ) -> Bool:
        """Check if all probes in the batch have completed.

        Args:
            probes: Pointer to the probe array.
            count: Number of probes in the array.

        Returns:
            True if every probe's is_done() returns True.
        """
        for i in range(count):
            if not (probes + i)[].is_done():
                return False
        return True

    @staticmethod
    def _drain_batch(
        probes: UnsafePointer[ConnectProbe, MutAnyOrigin],
        count: Int,
        mut loop: CompletionLoop,
    ):
        """Drain in-flight probes until done, with bounded iteration.

        Used in exception handlers to ensure all CQEs are consumed before
        destroying probes, preventing kernel-side use-after-free of
        completion token pointers.

        Bounded at 30x the probe count (each probe produces at most 3 CQEs;
        10x safety margin accounts for spurious wakeups and flush retries).
        Hitting the bound implies kernel-level failure (lost SQEs) where
        safety is already compromised. Each iteration may block up to the
        probe timeout duration; worst-case wall-clock is count*30*timeout_ms.

        SQ-full during flush_cancel inside this loop is transient: run_once()
        calls tick(wait=True) which flushes pending SQEs before waiting,
        so SQ space recovers on the next iteration.

        Args:
            probes: Pointer to the probe array.
            count: Number of in-flight probes to drain.
            loop: The completion loop to poll.
        """
        if count == 0:
            return
        var max_iters = count * 30
        var iters = 0
        while not Self._all_done(probes, count):
            if iters >= max_iters:
                break
            try:
                loop.run_once()
                for i in range(count):
                    (probes + i)[].flush_cancel(loop)
            except:
                pass
            iters += 1

    @staticmethod
    def _sort_results(mut results: List[ProbeResult]):
        """Sort results by port ascending using insertion sort.

        Insertion sort is optimal for the expected small N (typical port
        scan batches are 1-1000 ports).

        Args:
            results: The results list to sort in-place.
        """
        for i in range(1, len(results)):
            var key_port = results[i].port
            var key_status = results[i].status
            var j = i - 1
            while j >= 0 and results[j].port > key_port:
                results[j + 1] = ProbeResult(
                    port=results[j].port, status=results[j].status
                )
                j -= 1
            results[j + 1] = ProbeResult(port=key_port, status=key_status)
