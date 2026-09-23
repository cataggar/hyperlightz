const std = @import("std");
const hyperlight = @import("hyperlight");

fn double(call_count: *usize, value: i32) !i32 {
    call_count.* += 1;
    return value * 2;
}

fn stringLength(value: hyperlight.String) u64 {
    return value.bytes.len;
}

fn chunksEqual(chunks: []const []u8, expected: []const u8) bool {
    var offset: usize = 0;
    for (chunks) |bytes| {
        if (bytes.len > expected.len - offset) return false;
        if (!std.mem.eql(u8, bytes, expected[offset..][0..bytes.len])) return false;
        offset += bytes.len;
    }
    return offset == expected.len;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedGuestPath;

    var builder = try hyperlight.host.Builder.initFromFile(init.arena.allocator(), args[1]);
    defer builder.deinit();

    var callback_calls: usize = 0;
    try builder.hostFunctionWithContext("HostDouble", &callback_calls, double);
    try builder.hostFunction("HostStringLength", stringLength);

    var sandbox = try builder.build();
    defer sandbox.deinit();

    const sum = try sandbox.call(i32, "Add", .{ @as(i32, 20), @as(i32, 22) });
    const doubled = try sandbox.call(i32, "CallHost", .{@as(i32, 21)});
    const string_length = try sandbox.call(u64, "CallHostString", .{});
    var greeting = try sandbox.call(hyperlight.String, "Greeting", .{});
    defer greeting.deinit();
    var echoed_bytes = try sandbox.call(
        hyperlight.Bytes,
        "EchoBytes",
        .{hyperlight.bytes("bytes")},
    );
    defer echoed_bytes.deinit();
    const input_chunks = [_]hyperlight.Chunk{
        hyperlight.chunk("first"),
        hyperlight.chunk("second"),
    };
    var echoed_chunks = try sandbox.call(
        hyperlight.ByteChunks,
        "EchoByteChunks",
        .{hyperlight.byteChunks(&input_chunks)},
    );
    defer echoed_chunks.deinit();
    try sandbox.call(void, "NoOp", .{});

    if (sum != 42 or
        doubled != 42 or
        callback_calls != 1 or
        string_length != 5 or
        !std.mem.eql(u8, greeting.bytes, "hello from Zig") or
        !std.mem.eql(u8, echoed_bytes.bytes, "bytes") or
        !chunksEqual(echoed_chunks.chunks, "firstsecond"))
    {
        return error.UnexpectedResult;
    }

    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.print(
        "Add returned {d}; guest-to-host callback returned {d}\n",
        .{ sum, doubled },
    );
    try stdout_writer.interface.flush();
}
