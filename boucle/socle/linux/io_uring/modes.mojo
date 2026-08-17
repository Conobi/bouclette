from boucle.socle.linux.raw import (
    IORING_SETUP_IOPOLL,
    IORING_SETUP_SQPOLL,
)


@__nonmaterializable(NoneType)
struct PollingMode(TrivialRegisterPassable, Identifiable):
    var id: UInt8
    var setup_flags: UInt32

    @always_inline
    def __init__(out self, *, id: UInt8, setup_flags: UInt32):
        self.id = id
        self.setup_flags = setup_flags

    @always_inline
    def __is__(self, rhs: Self) -> Bool:
        """Defines whether one PollingMode has the same identity as another.

        Args:
            rhs: The PollingMode to compare against.

        Returns:
            True if the PollingModes have the same identity, False otherwise.
        """
        return self.id == rhs.id and self.setup_flags == rhs.setup_flags

    @always_inline
    def __isnot__(self, rhs: Self) -> Bool:
        """Defines whether one PollingMode has a different identity than another.

        Args:
            rhs: The PollingMode to compare against.

        Returns:
            True if the PollingModes have different identities, False otherwise.
        """
        return self.id != rhs.id or self.setup_flags != rhs.setup_flags


comptime NOPOLL = PollingMode(id=0, setup_flags=0)
comptime IOPOLL = PollingMode(id=1, setup_flags=IORING_SETUP_IOPOLL)
comptime SQPOLL = PollingMode(id=2, setup_flags=IORING_SETUP_SQPOLL)
