#ifndef HYPERLIGHTZ_H
#define HYPERLIGHTZ_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
  HLZ_TYPE_VOID = 0,
  HLZ_TYPE_INT = 1,
  HLZ_TYPE_UINT = 2,
  HLZ_TYPE_LONG = 3,
  HLZ_TYPE_ULONG = 4,
  HLZ_TYPE_FLOAT = 5,
  HLZ_TYPE_DOUBLE = 6,
  HLZ_TYPE_BOOL = 7,
  HLZ_TYPE_STRING = 8,
  HLZ_TYPE_VEC_BYTES = 9,
  HLZ_TYPE_BYTE_CHUNKS = 10,
} hlz_type;

typedef struct {
  const uint8_t *data;
  size_t len;
} hlz_bytes;

typedef struct {
  const hlz_bytes *chunks;
  size_t len;
} hlz_byte_chunks;

typedef union {
  int32_t int_value;
  uint32_t uint_value;
  int64_t long_value;
  uint64_t ulong_value;
  float float_value;
  double double_value;
  bool bool_value;
  hlz_bytes bytes_value;
  hlz_byte_chunks chunks_value;
} hlz_value_data;

typedef struct {
  hlz_type tag;
  hlz_value_data value;
} hlz_value;

typedef enum {
  HLZ_STATUS_OK = 0,
  HLZ_STATUS_INVALID_ARGUMENT = 1,
  HLZ_STATUS_HYPERLIGHT_ERROR = 2,
  HLZ_STATUS_CALLBACK_ERROR = 3,
  HLZ_STATUS_PANIC = 4,
} hlz_status;

typedef struct {
  uint8_t *data;
  size_t len;
} hlz_error;

typedef struct hlz_builder hlz_builder;
typedef struct hlz_sandbox hlz_sandbox;
typedef struct hlz_snapshot hlz_snapshot;

typedef hlz_status (*hlz_host_callback)(void *context, const hlz_value *args,
                                        size_t args_len, hlz_value *result,
                                        hlz_bytes *error);

hlz_status hlz_builder_from_file(hlz_bytes path, hlz_builder **builder_out,
                                 hlz_error *error);
hlz_status hlz_builder_host_function(
    hlz_builder *builder, hlz_bytes name, const hlz_type *parameter_types,
    size_t parameter_count, hlz_type return_type, hlz_host_callback callback,
    void *context, hlz_error *error);
hlz_status hlz_builder_build(hlz_builder *builder, hlz_sandbox **sandbox_out,
                             hlz_error *error);
hlz_status hlz_sandbox_call(hlz_sandbox *sandbox, hlz_bytes function_name,
                            hlz_type return_type, const hlz_value *args,
                            size_t args_len, hlz_value *result_out,
                            hlz_error *error);
hlz_status hlz_sandbox_snapshot(hlz_sandbox *sandbox,
                                hlz_snapshot **snapshot_out, hlz_error *error);
hlz_status hlz_sandbox_restore(hlz_sandbox *sandbox,
                               const hlz_snapshot *snapshot, hlz_error *error);

void hlz_error_deinit(hlz_error *error);
void hlz_value_deinit(hlz_value *value);
void hlz_builder_deinit(hlz_builder *builder);
void hlz_sandbox_deinit(hlz_sandbox *sandbox);
void hlz_snapshot_deinit(hlz_snapshot *snapshot);

#endif
