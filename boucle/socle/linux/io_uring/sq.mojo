from .mm import Region
from .modes import PollingMode, SQPOLL
from .utils import AtomicOrdering, _atomic_load, _atomic_store
from boucle.socle.linux.io_uring.types import (
    Sqe,
    SQE,
    SQE64,
    SQE128,
    IoUringParams,
    IoUringSetupFlags,
    IoUringOp,
    IoUringSqeFlags,
    addr3_struct,
)
from boucle.socle.linux.utils import _size_eq, _align_eq
from boucle.socle.ptr import null_ptr
from std.memory import UnsafePointer


@always_inline
def _nop_data[
    type: SQE, origin: MutOrigin
](ref [origin]sqe: Sqe[type]) -> ref [origin] Sqe[type]:
    sqe.opcode = IoUringOp.NOP
    sqe.flags = IoUringSqeFlags.CQE_SKIP_SUCCESS
    return sqe


struct Sq[type: SQE, polling: PollingMode](Movable, Sized, Boolable):
    """Submission Queue."""

    var _head: UnsafePointer[UInt32, StaticConstantOrigin]
    var _tail: UnsafePointer[UInt32, StaticConstantOrigin]
    var _flags: UnsafePointer[UInt32, StaticConstantOrigin]
    var dropped: UnsafePointer[UInt32, StaticConstantOrigin]

    var array: UnsafePointer[UInt32, StaticConstantOrigin]
    var sqes: UnsafePointer[Sqe[Self.type], StaticConstantOrigin]

    var sqe_head: UInt32
    var sqe_tail: UInt32

    var ring_mask: UInt32
    var ring_entries: UInt32

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    def __init__(
        out self,
        params: IoUringParams,
        *,
        sq_cq_mem: Region,
        sqes_mem: Region,
    ) raises:
        comptime assert Self.type is SQE64 or Self.type is SQE128, "SQE must be equal to SQE64 or SQE128"
        _size_eq[Sqe[Self.type]](Self.type.size)
        _align_eq[Sqe[Self.type]](Self.type.align)

        self._head = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.sq_off.head, count=1
        )
        self._tail = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.sq_off.tail, count=1
        )
        self._flags = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.sq_off.flags, count=1
        )
        self.dropped = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.sq_off.dropped, count=1
        )
        self.ring_mask = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.sq_off.ring_mask, count=1
        )[]
        self.ring_entries = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.sq_off.ring_entries, count=1
        )[]
        # We expect the kernel copies `params.sq_entries` to the UInt32
        # pointed to by `params.sq_off.ring_entries`.
        # [Linux]: https://github.com/torvalds/linux/blob/v6.7/io_uring/io_uring.c#L38.
        if self.ring_entries != params.sq_entries or self.ring_entries == 0:
            raise "invalid sq ring_entries value"
        if self.ring_mask != self.ring_entries - 1:
            raise "invalid sq ring_mask value"

        if params.flags & IoUringSetupFlags.NO_SQARRAY:
            self.array = null_ptr[UInt32, StaticConstantOrigin]()
        else:
            self.array = sq_cq_mem.unsafe_ptr[UInt32](
                offset=params.sq_off.array, count=self.ring_entries
            )
            # Directly map `sq` slots to `sqes`.
            for i in range(self.ring_entries):
                _atomic_store(self.array + i, UInt32(i))

        self.sqes = sqes_mem.unsafe_ptr[Sqe[Self.type]](
            offset=0, count=self.ring_entries
        )
        self.sqe_head = self._head[]
        self.sqe_tail = self._tail[]

    @always_inline
    def __init__(out self, *, deinit take: Self):
        """Moves data of an existing Sq into a new one.

        Args:
            take: The existing Sq.
        """
        self._head = take._head
        self._tail = take._tail
        self._flags = take._flags
        self.dropped = take.dropped
        self.array = take.array
        self.sqes = take.sqes
        self.sqe_head = take.sqe_head
        self.sqe_tail = take.sqe_tail
        self.ring_mask = take.ring_mask
        self.ring_entries = take.ring_entries

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    @always_inline
    def __len__(self) -> Int:
        """Returns the number of available sq entries.

        Returns:
            The number of available sq entries.
        """
        return Int(self.ring_entries - (self.sqe_tail - self.sqe_head))

    @always_inline
    def __bool__(self) -> Bool:
        """Checks whether the sq has any available entries or not.

        Returns:
            `False` if the sq is full, `True` if there is at least one available
            entry.
        """
        return self.sqe_tail - self.sqe_head != self.ring_entries

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    def sync_head(mut self):
        self.sqe_head = self.head[AtomicOrdering.ACQUIRE]()

    @always_inline
    def head[ordering: AtomicOrdering](self) -> UInt32:
        comptime if Self.polling is SQPOLL:
            return _atomic_load[ordering](self._head)
        else:
            return self._head[]

    @always_inline
    def sync_tail(mut self):
        comptime if Self.polling is SQPOLL:
            _atomic_store(self._tail, self.sqe_tail)
        else:
            _atomic_store(self._tail, self.sqe_tail)

    @always_inline
    def flush(mut self) -> UInt32:
        if self.sqe_head != self.sqe_tail:
            self.sqe_head = self.sqe_tail
            # Ensure that the kernel can actually see the sqe updates
            # when it sees the tail update.
            self.sync_tail()

        # `self.head()` load needs to be atomic when we're in SQPOLL mode
        # since head is written concurrently by the kernel, but it
        # doesn't need to be `AtomicOrdering.ACQUIRE`, since the kernel
        # doesn't store to the submission queue. It advances head just to
        # indicate that it's finished reading the submission queue entries
        # so they're available for us to write to.
        return self.sqe_tail - self.head[AtomicOrdering.RELAXED]()

    @always_inline
    def flags(self) -> UInt32:
        return _atomic_load[AtomicOrdering.RELAXED](self._flags)


struct SqPtr[type: SQE, polling: PollingMode, sq_origin: MutOrigin](
    RegisterPassable, Sized, Boolable
):
    var sq: Pointer[Sq[Self.type, Self.polling], Self.sq_origin]

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    @implicit
    @always_inline
    def __init__(out self, ref [Self.sq_origin]sq: Sq[Self.type, Self.polling]):
        self.sq = Pointer(to=sq)

    # ===------------------------------------------------------------------=== #
    # Operator dunders
    # ===------------------------------------------------------------------=== #

    @always_inline
    def __iter__(var self) -> Self:
        return self^

    @always_inline
    def __next__[
        origin: MutOrigin
    ](ref [origin]self) -> ref [origin] Sqe[Self.type]:
        ptr = self.sq[].sqes + (self.sq[].sqe_tail & self.sq[].ring_mask)
        self.sq[].sqe_tail += 1
        mut_ptr = rebind[UnsafePointer[Sqe[Self.type], origin]](ptr)
        return _nop_data(mut_ptr[])

    @always_inline
    def __has_next__(self) -> Bool:
        return self.__len__() > 0

    # ===------------------------------------------------------------------=== #
    # Trait implementations
    # ===------------------------------------------------------------------=== #

    @always_inline
    def __len__(self) -> Int:
        """Returns the number of available sq entries.

        Returns:
            The number of available sq entries.
        """
        return len(self.sq[])

    @always_inline
    def __bool__(self) -> Bool:
        """Checks whether the sq has any available entries or not.

        Returns:
            `False` if the sq is full, `True` if there is at least one available
            entry.
        """
        return Bool(self.sq[])
