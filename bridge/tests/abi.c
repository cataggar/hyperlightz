#include "hyperlightz.h"

#include <stddef.h>

_Static_assert(HLZ_TYPE_VOID == 0, "hlz_type discriminants changed");
_Static_assert(HLZ_TYPE_BYTE_CHUNKS == 10, "hlz_type discriminants changed");
_Static_assert(HLZ_STATUS_OK == 0, "hlz_status discriminants changed");
_Static_assert(HLZ_STATUS_PANIC == 4, "hlz_status discriminants changed");
_Static_assert(sizeof(hlz_type) == sizeof(int), "hlz_type must use the C enum ABI");
_Static_assert(sizeof(hlz_status) == sizeof(int), "hlz_status must use the C enum ABI");
_Static_assert(sizeof(hlz_bytes) == 2 * sizeof(void *), "hlz_bytes layout changed");
_Static_assert(sizeof(hlz_byte_chunks) == sizeof(hlz_bytes),
               "hlz_byte_chunks layout changed");
_Static_assert(offsetof(hlz_value, value) % _Alignof(hlz_value_data) == 0,
               "hlz_value union is misaligned");
