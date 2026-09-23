const std = @import("std");
const abi = @import("abi.zig");

pub const String = struct {
    bytes: []const u8,
};

pub const Bytes = struct {
    bytes: []const u8,
};

pub const Chunk = extern struct {
    data: ?[*]const u8,
    len: usize,
};

pub const ByteChunks = struct {
    chunks: []const Chunk,
};

pub const OwnedString = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *OwnedString) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const OwnedBytes = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *OwnedBytes) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const OwnedByteChunks = struct {
    allocator: std.mem.Allocator,
    chunks: [][]u8,

    pub fn deinit(self: *OwnedByteChunks) void {
        for (self.chunks) |item| self.allocator.free(item);
        self.allocator.free(self.chunks);
        self.* = undefined;
    }
};

pub fn string(value: []const u8) String {
    return .{ .bytes = value };
}

pub fn bytes(value: []const u8) Bytes {
    return .{ .bytes = value };
}

pub fn chunk(value: []const u8) Chunk {
    return .{
        .data = if (value.len == 0) null else value.ptr,
        .len = value.len,
    };
}

pub fn byteChunks(chunks: []const Chunk) ByteChunks {
    return .{ .chunks = chunks };
}

pub fn WireResult(comptime T: type) type {
    return if (T == String)
        OwnedString
    else if (T == Bytes)
        OwnedBytes
    else if (T == ByteChunks)
        OwnedByteChunks
    else
        T;
}

pub fn wireType(comptime T: type) abi.Type {
    if (T == void) return .void;
    if (T == i32) return .int;
    if (T == u32) return .uint;
    if (T == i64) return .long;
    if (T == u64) return .ulong;
    if (T == f32) return .float;
    if (T == f64) return .double;
    if (T == bool) return .bool;
    if (T == String or T == OwnedString) return .string;
    if (T == Bytes or T == OwnedBytes) return .vec_bytes;
    if (T == ByteChunks or T == OwnedByteChunks) return .byte_chunks;
    @compileError("unsupported Hyperlight value type: " ++ @typeName(T));
}

fn bytesView(value: []const u8) abi.Bytes {
    return .{
        .data = if (value.len == 0) null else value.ptr,
        .len = value.len,
    };
}

pub fn toAbi(value: anytype) abi.Value {
    const T = @TypeOf(value);
    return if (T == i32)
        .{ .tag = .int, .value = .{ .int_value = value } }
    else if (T == u32)
        .{ .tag = .uint, .value = .{ .uint_value = value } }
    else if (T == i64)
        .{ .tag = .long, .value = .{ .long_value = value } }
    else if (T == u64)
        .{ .tag = .ulong, .value = .{ .ulong_value = value } }
    else if (T == f32)
        .{ .tag = .float, .value = .{ .float_value = value } }
    else if (T == f64)
        .{ .tag = .double, .value = .{ .double_value = value } }
    else if (T == bool)
        .{ .tag = .bool, .value = .{ .bool_value = value } }
    else if (T == String)
        .{ .tag = .string, .value = .{ .bytes_value = bytesView(value.bytes) } }
    else if (T == Bytes)
        .{ .tag = .vec_bytes, .value = .{ .bytes_value = bytesView(value.bytes) } }
    else if (T == ByteChunks)
        .{
            .tag = .byte_chunks,
            .value = .{
                .chunks_value = .{
                    .chunks = if (value.chunks.len == 0)
                        null
                    else
                        @ptrCast(value.chunks.ptr),
                    .len = value.chunks.len,
                },
            },
        }
    else
        @compileError("unsupported Hyperlight parameter type: " ++ @typeName(T));
}

fn requireTag(value: abi.Value, expected: abi.Type) !void {
    if (value.tag != expected) return error.TypeMismatch;
}

fn sliceFromView(value: abi.Bytes) ![]const u8 {
    if (value.len == 0) return &.{};
    const data = value.data orelse return error.InvalidArgument;
    return data[0..value.len];
}

pub fn fromAbiBorrowed(comptime T: type, value: abi.Value) !T {
    try requireTag(value, wireType(T));
    return if (T == i32)
        value.value.int_value
    else if (T == u32)
        value.value.uint_value
    else if (T == i64)
        value.value.long_value
    else if (T == u64)
        value.value.ulong_value
    else if (T == f32)
        value.value.float_value
    else if (T == f64)
        value.value.double_value
    else if (T == bool)
        value.value.bool_value
    else if (T == String)
        .{ .bytes = try sliceFromView(value.value.bytes_value) }
    else if (T == Bytes)
        .{ .bytes = try sliceFromView(value.value.bytes_value) }
    else if (T == ByteChunks) blk: {
        const chunks = value.value.chunks_value;
        if (chunks.len == 0) break :blk .{ .chunks = &.{} };
        const data = chunks.chunks orelse return error.InvalidArgument;
        break :blk .{ .chunks = @ptrCast(data[0..chunks.len]) };
    } else if (T == void) {} else @compileError("unsupported Hyperlight return type: " ++ @typeName(T));
}

pub fn fromAbiOwned(
    allocator: std.mem.Allocator,
    comptime T: type,
    value: abi.Value,
) !WireResult(T) {
    if (T == String) {
        const borrowed = try fromAbiBorrowed(String, value);
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, borrowed.bytes),
        };
    }
    if (T == Bytes) {
        const borrowed = try fromAbiBorrowed(Bytes, value);
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, borrowed.bytes),
        };
    }
    if (T == ByteChunks) {
        const borrowed = try fromAbiBorrowed(ByteChunks, value);
        const chunks = try allocator.alloc([]u8, borrowed.chunks.len);
        var initialized: usize = 0;
        errdefer {
            for (chunks[0..initialized]) |item| allocator.free(item);
            allocator.free(chunks);
        }
        for (borrowed.chunks, 0..) |item, index| {
            const bytes_slice = if (item.len == 0)
                &.{}
            else
                (item.data orelse return error.InvalidArgument)[0..item.len];
            chunks[index] = try allocator.dupe(u8, bytes_slice);
            initialized += 1;
        }
        return .{ .allocator = allocator, .chunks = chunks };
    }
    return fromAbiBorrowed(T, value);
}

test "maps supported types at comptime" {
    try std.testing.expectEqual(abi.Type.int, wireType(i32));
    try std.testing.expectEqual(abi.Type.string, wireType(String));
    try std.testing.expectEqual(abi.Type.byte_chunks, wireType(ByteChunks));
}

test "scalar and borrowed values round trip" {
    const int_value = toAbi(@as(i32, 42));
    try std.testing.expectEqual(@as(i32, 42), try fromAbiBorrowed(i32, int_value));

    const string_value = toAbi(string("hello"));
    const actual = try fromAbiBorrowed(String, string_value);
    try std.testing.expectEqualStrings("hello", actual.bytes);
}

comptime {
    if (@sizeOf(Chunk) != @sizeOf(abi.Bytes) or
        @alignOf(Chunk) != @alignOf(abi.Bytes))
    {
        @compileError("Chunk must match the bridge byte-slice ABI");
    }
}
