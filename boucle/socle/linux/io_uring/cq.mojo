from .mm import Region
from .utils import AtomicOrdering, _atomic_load, _atomic_store
from boucle.socle.linux.io_uring.types import (
    Cqe,
    CQE,
    CQE16,
    CQE32,
    IoUringParams,
)
from boucle.socle.linux.utils import _size_eq, _align_eq
from std.memory import Pointer


struct Cq[type: CQE](Movable, Sized, Boolable):
    """Completion Queue."""

    var _head: Pointer[UInt32, ImmStaticOrigin]
    var _tail: Pointer[UInt32, ImmStaticOrigin]
    var flags: Pointer[UInt32, ImmStaticOrigin]
    var overflow: Pointer[UInt32, ImmStaticOrigin]
    var cqes: Pointer[Cqe[Self.type], ImmStaticOrigin]

    var cqe_head: UInt32
    var cqe_tail: UInt32

    var ring_mask: UInt32
    var ring_entries: UInt32

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    def __init__(out self, params: IoUringParams, *, sq_cq_mem: Region) raises:
        comptime assert Self.type is CQE16 or Self.type is CQE32, "CQE must be equal to CQE16 or CQE32"
        _size_eq[Cqe[Self.type]](Self.type.size)
        _align_eq[Cqe[Self.type]](Self.type.align)

        self._head = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.cq_off.head, count=1
        )
        self._tail = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.cq_off.tail, count=1
        )
        self.flags = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.cq_off.flags, count=1
        )
        self.overflow = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.cq_off.overflow, count=1
        )
        self.ring_mask = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.cq_off.ring_mask, count=1
        )[]
        self.ring_entries = sq_cq_mem.unsafe_ptr[UInt32](
            offset=params.cq_off.ring_entries, count=1
        )[]
        # We expect the kernel copies `params.cq_entries` to the UInt32
        # pointed to by `params.cq_off.ring_entries`.
        # [Linux]: https://github.com/torvalds/linux/blob/v6.7/io_uring/io_uring.c#L3830.
        if self.ring_entries != params.cq_entries or self.ring_entries == 0:
            raise "invalid cq ring_entries value"
        if self.ring_mask != self.ring_entries - 1:
            raise "invalid cq ring_mask value"

        self.cqes = sq_cq_mem.unsafe_ptr[Cqe[Self.type]](
            offset=params.cq_off.cqes, count=self.ring_entries
        )
        self.cqe_head = self._head[]
        self.cqe_tail = self._tail[]

    @always_inline
    def __init__(out self, *, deinit move: Self):
        """Moves data of an existing Cq into a new one.

        Args:
            move: The existing Cq.
        """
        self._head = move._head
        self._tail = move._tail
        self.flags = move.flags
        self.overflow = move.overflow
        self.cqes = move.cqes
        self.cqe_head = move.cqe_head
        self.cqe_tail = move.cqe_tail
        self.ring_mask = move.ring_mask
        self.ring_entries = move.ring_entries

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    @always_inline
    def __len__(self) -> Int:
        """Returns the number of entries in the cq.

        Returns:
            The number of entries in the cq.
        """
        return Int(self.cqe_tail - self.cqe_head)

    @always_inline
    def __bool__(self) -> Bool:
        """Checks whether the cq has any entries or not.

        Returns:
            `False` if the cq is empty, `True` if there is at least one entry.
        """
        return self.cqe_head != self.cqe_tail

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    def sync_tail(mut self):
        self.cqe_tail = self.tail()

    @always_inline
    def sync_head(self):
        _atomic_store(self._head, self.cqe_head)

    @always_inline
    def tail(self) -> UInt32:
        return _atomic_load[AtomicOrdering.ACQUIRE](self._tail)


struct CqPtr[type: CQE, cq_origin: MutOrigin](RegisterPassable, Sized, Boolable):
    var cq: Pointer[Cq[Self.type], Self.cq_origin]

    # ===------------------------------------------------------------------=== #
    # Life cycle methods
    # ===------------------------------------------------------------------=== #

    @implicit
    @always_inline
    def __init__(out self, ref [Self.cq_origin]cq: Cq[Self.type]):
        self.cq = Pointer(to=cq)

    @always_inline
    def __deinit__(deinit self):
        self.cq[].sync_head()

    # ===------------------------------------------------------------------=== #
    # Operator dunders
    # ===------------------------------------------------------------------=== #

    @always_inline
    def __iter__(var self) -> Self:
        return self^

    @always_inline
    def __next__[
        origin: MutOrigin
    ](ref [origin]self) -> ref [origin] Cqe[
        Self.type
    ]:
        var ptr = self.cq[].cqes.unsafe_offset(self.cq[].cqe_head & self.cq[].ring_mask)
        self.cq[].cqe_head += 1
        var mut_ptr = rebind[Pointer[Cqe[Self.type], origin]](ptr)
        return mut_ptr[]

    @always_inline
    def __has_next__(self) -> Bool:
        return self.__len__() > 0

    # ===------------------------------------------------------------------=== #
    # Trait implementations
    # ===------------------------------------------------------------------=== #

    @always_inline
    def __len__(self) -> Int:
        """Returns the number of entries in the cq.

        Returns:
            The number of entries in the cq.
        """
        return len(self.cq[])

    @always_inline
    def __bool__(self) -> Bool:
        """Checks whether the cq has any entries or not.

        Returns:
            `False` if the cq is empty, `True` if there is at least one entry.
        """
        return Bool(self.cq[])
