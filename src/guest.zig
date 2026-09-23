const std = @import("std");
const abi = @import("guest_abi.zig");
const types = @import("types.zig");

pub const Error = error{
    HostFunctionFailed,
    InvalidReturnType,
    OutOfMemory,
};

fn parameterType(comptime T: type) abi.ParameterType {
    return switch (T) {
        i32 => .int,
        u32 => .uint,
        i64 => .long,
        u64 => .ulong,
        f32 => .float,
        f64 => .double,
        bool => .bool,
        types.String => .string,
        types.Bytes => .bytes,
        types.ByteChunks => .byte_chunks,
        else => @compileError("unsupported Hyperlight guest parameter type: " ++ @typeName(T)),
    };
}

fn returnType(comptime T: type) abi.ReturnType {
    return switch (T) {
        i32 => .int,
        u32 => .uint,
        i64 => .long,
        u64 => .ulong,
        f32 => .float,
        f64 => .double,
        bool => .bool,
        void => .void,
        types.String => .string,
        types.Bytes => .bytes,
        types.ByteChunks => .byte_chunks,
        else => @compileError("unsupported Hyperlight guest return type: " ++ @typeName(T)),
    };
}

fn payloadType(comptime Return: type) type {
    return switch (@typeInfo(Return)) {
        .error_union => |info| info.payload,
        else => Return,
    };
}

const EncodedParameter = struct {
    value: abi.Parameter,
    allocation: ?*anyopaque = null,

    fn deinit(self: EncodedParameter) void {
        if (self.allocation) |allocation| abi.free(allocation);
    }
};

fn encode(value: anytype) Error!EncodedParameter {
    const T = @TypeOf(value);
    var allocation: ?*anyopaque = null;
    const encoded_value: abi.Value = switch (T) {
        i32 => .{ .int = value },
        u32 => .{ .uint = value },
        i64 => .{ .long = value },
        u64 => .{ .ulong = value },
        f32 => .{ .float = value },
        f64 => .{ .double = value },
        bool => .{ .bool = value },
        types.String => string: {
            const raw = abi.malloc(value.bytes.len + 1) orelse
                return error.OutOfMemory;
            allocation = raw;
            const buffer: [*]u8 = @ptrCast(raw);
            @memcpy(buffer[0..value.bytes.len], value.bytes);
            buffer[value.bytes.len] = 0;
            break :string .{ .string = @ptrCast(buffer) };
        },
        types.Bytes => .{ .bytes = .{
            .data = @constCast(value.bytes.ptr),
            .len = value.bytes.len,
        } },
        types.ByteChunks => .{ .byte_chunks = .{
            .chunks = @ptrCast(value.chunks.ptr),
            .count = value.chunks.len,
        } },
        else => unreachable,
    };
    return .{
        .value = .{
            .tag = parameterType(T),
            .value = encoded_value,
        },
        .allocation = allocation,
    };
}

fn decode(comptime T: type, parameter: abi.Parameter) !T {
    if (parameter.tag != parameterType(T)) return error.InvalidReturnType;
    return switch (T) {
        i32 => parameter.value.int,
        u32 => parameter.value.uint,
        i64 => parameter.value.long,
        u64 => parameter.value.ulong,
        f32 => parameter.value.float,
        f64 => parameter.value.double,
        bool => parameter.value.bool,
        types.String => .{ .bytes = std.mem.span(parameter.value.string) },
        types.Bytes => .{ .bytes = parameter.value.bytes.data[0..parameter.value.bytes.len] },
        types.ByteChunks => .{
            .chunks = @as(
                [*]const types.Chunk,
                @ptrCast(parameter.value.byte_chunks.chunks),
            )[0..parameter.value.byte_chunks.count],
        },
        else => unreachable,
    };
}

fn decodeResult(comptime T: type, value: abi.ReturnValue) Error!T {
    if (value.tag != returnType(T)) return error.InvalidReturnType;
    return switch (T) {
        void => {},
        i32 => value.value.int,
        u32 => value.value.uint,
        i64 => value.value.long,
        u64 => value.value.ulong,
        f32 => value.value.float,
        f64 => value.value.double,
        bool => value.value.bool,
        types.String => .{ .bytes = std.mem.span(value.value.string) },
        types.Bytes => .{ .bytes = value.value.bytes.data[0..value.value.bytes.len] },
        types.ByteChunks => .{
            .chunks = @as(
                [*]const types.Chunk,
                @ptrCast(value.value.byte_chunks.chunks),
            )[0..value.value.byte_chunks.count],
        },
        else => unreachable,
    };
}

pub fn HostResult(comptime T: type) type {
    _ = returnType(T);
    return struct {
        raw: *abi.ReturnValue,

        pub fn value(self: @This()) Error!T {
            return decodeResult(T, self.raw.*);
        }

        pub fn deinit(self: *@This()) void {
            abi.hl_free_return_value(self.raw);
            self.* = undefined;
        }
    };
}

pub fn call(
    comptime Return: type,
    comptime name: []const u8,
    args: anytype,
) Error!HostResult(Return) {
    const Args = @TypeOf(args);
    const info = @typeInfo(Args);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("Hyperlight guest call arguments must be a tuple");
    }
    if (comptime std.mem.indexOfScalar(u8, name, 0) != null) {
        @compileError("Hyperlight function names cannot contain NUL bytes");
    }

    var encoded: [info.@"struct".fields.len]EncodedParameter = undefined;
    var initialized: usize = 0;
    defer for (encoded[0..initialized]) |parameter| parameter.deinit();
    var parameters: [info.@"struct".fields.len]abi.Parameter = undefined;
    inline for (info.@"struct".fields, 0..) |field, index| {
        encoded[index] = try encode(@field(args, field.name));
        initialized += 1;
        parameters[index] = encoded[index].value;
    }
    const call_value = abi.FunctionCall{
        .function_name = @ptrCast((name ++ "\x00").ptr),
        .parameters = &parameters,
        .parameters_len = parameters.len,
        .return_type = returnType(Return),
    };
    return .{
        .raw = abi.hl_call_host_function_with_result(&call_value) orelse
            return error.HostFunctionFailed,
    };
}

fn reportError(message: []const u8) void {
    var buffer: [128:0]u8 = @splat(0);
    const length = @min(message.len, buffer.len - 1);
    @memcpy(buffer[0..length], message[0..length]);
    abi.hl_set_error(.guest_error, &buffer);
}

fn makeResult(value: anytype) ?*abi.ReturnValue {
    const T = @TypeOf(value);
    return switch (T) {
        void => abi.hl_result_from_Void(),
        i32 => abi.hl_result_from_Int(value),
        u32 => abi.hl_result_from_UInt(value),
        i64 => abi.hl_result_from_Long(value),
        u64 => abi.hl_result_from_ULong(value),
        f32 => abi.hl_result_from_Float(value),
        f64 => abi.hl_result_from_Double(value),
        bool => abi.hl_result_from_Bool(value),
        types.String => abi.hl_result_from_StringBytes(value.bytes.ptr, value.bytes.len),
        types.Bytes => abi.hl_result_from_Bytes(value.bytes.ptr, value.bytes.len),
        types.ByteChunks => abi.hl_result_from_ByteChunks(.{
            .chunks = @ptrCast(value.chunks.ptr),
            .count = value.chunks.len,
        }),
        else => unreachable,
    };
}

fn parameterTypes(comptime function: anytype) type {
    const function_info = @typeInfo(@TypeOf(function));
    if (function_info != .@"fn") {
        @compileError("Hyperlight guest binding must refer to a function");
    }
    return [function_info.@"fn".params.len]abi.ParameterType;
}

fn makeParameterTypes(comptime function: anytype) parameterTypes(function) {
    const params = @typeInfo(@TypeOf(function)).@"fn".params;
    var result: [params.len]abi.ParameterType = undefined;
    inline for (params, 0..) |param, index| {
        const Param = param.type orelse
            @compileError("generic parameters are not supported in Hyperlight guest functions");
        result[index] = parameterType(Param);
    }
    return result;
}

fn Trampoline(comptime function: anytype) type {
    return struct {
        fn invoke(call_value: *const abi.FunctionCall) callconv(.c) ?*abi.ReturnValue {
            const function_info = @typeInfo(@TypeOf(function)).@"fn";
            if (call_value.parameters_len != function_info.params.len) {
                reportError("guest function argument count mismatch");
                return null;
            }
            var args: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            inline for (function_info.params, 0..) |param, index| {
                const Param = param.type orelse unreachable;
                args[index] = decode(Param, call_value.parameters[index]) catch {
                    reportError("guest function argument type mismatch");
                    return null;
                };
            }

            const Return = function_info.return_type orelse
                @compileError("Hyperlight guest function must have a return type");
            const Payload = payloadType(Return);
            const payload: Payload = switch (@typeInfo(Return)) {
                .error_union => @call(.auto, function, args) catch |err| {
                    reportError(@errorName(err));
                    return null;
                },
                else => @call(.auto, function, args),
            };
            const result = makeResult(payload);
            if (result == null) reportError("failed to create guest function result");
            return result;
        }
    };
}

fn Registry(comptime functions: anytype) type {
    const Functions = @TypeOf(functions);
    const info = @typeInfo(Functions);
    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError("guest exports must be a named anonymous struct");
    }

    return struct {
        fn initialize() callconv(.c) void {
            inline for (info.@"struct".fields) |field| {
                const function = @field(functions, field.name);
                const parameter_types = makeParameterTypes(function);
                const Return = @typeInfo(@TypeOf(function)).@"fn".return_type orelse
                    @compileError("Hyperlight guest function must have a return type");
                abi.hl_register_function_definition(
                    @ptrCast((field.name ++ "\x00").ptr),
                    &Trampoline(function).invoke,
                    parameter_types.len,
                    &parameter_types,
                    returnType(payloadType(Return)),
                );
            }
        }

        fn fallback(_: *const abi.FunctionCall) callconv(.c) ?*abi.ReturnValue {
            return null;
        }
    };
}

pub fn exportFunctions(comptime functions: anytype) void {
    const registry = Registry(functions);
    @export(&registry.initialize, .{ .name = "hyperlight_main" });
    @export(&registry.fallback, .{ .name = "c_guest_dispatch_function" });
}

comptime {
    if (@sizeOf(types.Chunk) != @sizeOf(abi.ByteChunk) or
        @alignOf(types.Chunk) != @alignOf(abi.ByteChunk))
    {
        @compileError("Hyperlight byte chunk ABI does not match its Zig wrapper");
    }
}

test "guest ABI tags match Hyperlight C API" {
    try std.testing.expectEqual(@as(c_int, 6), @intFromEnum(abi.ParameterType.string));
    try std.testing.expectEqual(@as(c_int, 8), @intFromEnum(abi.ReturnType.void));
    try std.testing.expectEqual(@as(c_int, 10), @intFromEnum(abi.ReturnType.byte_chunks));
    try std.testing.expectEqual(@sizeOf(abi.Parameter), @sizeOf(abi.ReturnValue));
}

test "guest parameter conversion is comptime driven" {
    const inputs = .{
        @as(i32, -4),
        types.bytes("abc"),
    };
    const first = try encode(inputs[0]);
    const second = try encode(inputs[1]);
    try std.testing.expectEqual(abi.ParameterType.int, first.value.tag);
    try std.testing.expectEqual(@as(i32, -4), try decode(i32, first.value));
    try std.testing.expectEqualStrings("abc", (try decode(types.Bytes, second.value)).bytes);
}
