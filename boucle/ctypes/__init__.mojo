"""Public ctypes bridge.

Re-exports a small set of C type aliases for consumers that wire up
`external_call` themselves without owning their own ctypes module. The
set is intentionally narrow — widen on demand rather than mirroring
every typedef from the platform facade.
"""

from boucle.socle.platform import (
    c_void,
    c_char,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_size_t,
    c_ssize_t,
)
