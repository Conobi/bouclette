"""Pure network probe primitives.

Provides value types and pure functions for port-scanning logic
that require no I/O (no io_uring dependency). These are the building
blocks for higher-level async probe operations.

- PortStatus: discriminates open / closed / filtered.
- ProbeResult: port number paired with its status.
- result_from_connect_cqe: maps a connect(2) CQE result to a PortStatus.
- BatchSpec / compute_batches: partitions N ports into concurrency-sized chunks.
- ProbeBatch: cooperative batch scanner with concurrency control.
"""

from .probe_batch import ProbeBatch


struct PortStatus(TrivialRegisterPassable, Equatable):
    """Discriminates port probe outcomes: OPEN, CLOSED, or FILTERED.

    Uses a UInt8 tag internally; equality is defined on the tag value.
    """

    comptime OPEN = Self(0)
    comptime CLOSED = Self(1)
    comptime FILTERED = Self(2)

    var _value: UInt8

    @always_inline("nodebug")
    @implicit
    def __init__(out self, value: UInt8):
        """Construct a PortStatus from a raw tag.

        Args:
            value: The numeric tag (0=OPEN, 1=CLOSED, 2=FILTERED).
        """
        self._value = value

    @always_inline("nodebug")
    def __eq__(self, other: Self) -> Bool:
        """Return True if both statuses represent the same outcome.

        Args:
            other: The status to compare against.

        Returns:
            True when internal tags match.
        """
        return self._value == other._value

    @always_inline("nodebug")
    def __ne__(self, other: Self) -> Bool:
        """Return True if statuses differ.

        Args:
            other: The status to compare against.

        Returns:
            True when internal tags do not match.
        """
        return self._value != other._value


struct ProbeResult(Movable):
    """A single port probe outcome: port number paired with status.

    Attributes:
        port: The TCP port number that was probed.
        status: The resulting PortStatus.
    """

    var port: Int
    var status: PortStatus

    def __init__(out self, *, port: Int, status: PortStatus):
        """Construct a ProbeResult.

        Args:
            port: The TCP port number.
            status: The probe outcome for that port.
        """
        self.port = port
        self.status = status

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source ProbeResult to move from.
        """
        self.port = move.port
        self.status = move.status


def result_from_connect_cqe(result: Int) -> PortStatus:
    """Map a connect(2) CQE result code to a PortStatus.

    Interprets the kernel return value from an async connect operation:
    - 0 means the connection succeeded (port is OPEN).
    - -ECONNREFUSED (-111) means the host actively rejected (CLOSED).
    - Anything else (timeout, no-route, etc.) means FILTERED.

    Args:
        result: The CQE res field from io_uring (negative errno on error).

    Returns:
        The corresponding PortStatus.
    """
    if result == 0:
        return PortStatus.OPEN
    if result == -111:
        return PortStatus.CLOSED
    return PortStatus.FILTERED


struct BatchSpec(Movable):
    """Describes one batch of ports to probe concurrently.

    Attributes:
        offset: Index of the first port in this batch within the total range.
        size: Number of ports in this batch.
    """

    var offset: Int
    var size: Int

    def __init__(out self, *, offset: Int, size: Int):
        """Construct a BatchSpec.

        Args:
            offset: Starting index within the total port range.
            size: Number of ports in this batch.
        """
        self.offset = offset
        self.size = size

    def __init__(out self, *, deinit move: Self):
        """Move constructor.

        Args:
            move: The source BatchSpec to move from.
        """
        self.offset = move.offset
        self.size = move.size


def compute_batches(*, total: Int, concurrency: Int) -> List[BatchSpec]:
    """Partition a total port count into concurrency-sized batches.

    Given N ports and a concurrency limit C, produces ceil(N/C) batch
    descriptors. Each batch has at most C ports; the final batch may
    be smaller.

    Args:
        total: Total number of ports to partition.
        concurrency: Maximum number of ports per batch.

    Returns:
        A list of BatchSpec values covering the entire range.
    """
    var result = List[BatchSpec]()
    if total == 0:
        return result^
    var offset = 0
    while offset < total:
        var remaining = total - offset
        var size = remaining if remaining < concurrency else concurrency
        result.append(BatchSpec(offset=offset, size=size))
        offset += size
    return result^
