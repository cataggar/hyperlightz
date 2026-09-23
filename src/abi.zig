pub const Type = enum(c_int) {
    void = 0,
    int = 1,
    uint = 2,
    long = 3,
    ulong = 4,
    float = 5,
    double = 6,
    bool = 7,
    string = 8,
    vec_bytes = 9,
    byte_chunks = 10,
};

pub const Bytes = extern struct {
    data: ?[*]const u8,
    len: usize,
};

pub const ByteChunks = extern struct {
    chunks: ?[*]const Bytes,
    len: usize,
};

pub const ValueData = extern union {
    int_value: i32,
    uint_value: u32,
    long_value: i64,
    ulong_value: u64,
    float_value: f32,
    double_value: f64,
    bool_value: bool,
    bytes_value: Bytes,
    chunks_value: ByteChunks,
};

pub const Value = extern struct {
    tag: Type,
    value: ValueData,

    pub fn initVoid() Value {
        return .{
            .tag = .void,
            .value = .{ .ulong_value = 0 },
        };
    }
};

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    hyperlight_error = 2,
    callback_error = 3,
    panic = 4,
};

pub const Error = extern struct {
    data: ?[*]u8,
    len: usize,

    pub fn init() Error {
        return .{ .data = null, .len = 0 };
    }
};

pub const Builder = opaque {};
pub const Sandbox = opaque {};
pub const Snapshot = opaque {};

pub const HostCallback = *const fn (
    context: ?*anyopaque,
    args: ?[*]const Value,
    args_len: usize,
    result: *Value,
    callback_error: *Bytes,
) callconv(.c) Status;

pub extern fn hlz_builder_from_file(
    path: Bytes,
    builder_out: *?*Builder,
    error_out: *Error,
) Status;
pub extern fn hlz_builder_host_function(
    builder: *Builder,
    name: Bytes,
    parameter_types: ?[*]const Type,
    parameter_count: usize,
    return_type: Type,
    callback: ?HostCallback,
    context: ?*anyopaque,
    error_out: *Error,
) Status;
pub extern fn hlz_builder_build(
    builder: *Builder,
    sandbox_out: *?*Sandbox,
    error_out: *Error,
) Status;
pub extern fn hlz_sandbox_call(
    sandbox: *Sandbox,
    function_name: Bytes,
    return_type: Type,
    args: ?[*]const Value,
    args_len: usize,
    result_out: *Value,
    error_out: *Error,
) Status;
pub extern fn hlz_sandbox_snapshot(
    sandbox: *Sandbox,
    snapshot_out: *?*Snapshot,
    error_out: *Error,
) Status;
pub extern fn hlz_sandbox_restore(
    sandbox: *Sandbox,
    snapshot: *const Snapshot,
    error_out: *Error,
) Status;

pub extern fn hlz_error_deinit(value: *Error) void;
pub extern fn hlz_value_deinit(value: *Value) void;
pub extern fn hlz_builder_deinit(value: *Builder) void;
pub extern fn hlz_sandbox_deinit(value: *Sandbox) void;
pub extern fn hlz_snapshot_deinit(value: *Snapshot) void;

const std = @import("std");

test "host bridge ABI layout is stable" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(Type.void));
    try std.testing.expectEqual(@as(c_int, 10), @intFromEnum(Type.byte_chunks));
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(Status.panic));
    try std.testing.expectEqual(@sizeOf(c_int), @sizeOf(Type));
    try std.testing.expectEqual(@sizeOf(c_int), @sizeOf(Status));
    try std.testing.expectEqual(2 * @sizeOf(usize), @sizeOf(Bytes));
    try std.testing.expectEqual(@sizeOf(Bytes), @sizeOf(ByteChunks));
    try std.testing.expectEqual(
        @as(usize, 0),
        @offsetOf(Value, "value") % @alignOf(ValueData),
    );
}

test "Rust bridge archive is linked" {
    var bridge_error = Error.init();
    hlz_error_deinit(&bridge_error);
}
