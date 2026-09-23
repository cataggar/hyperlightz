const hyperlight = @import("hyperlight");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn callHost(value: i32) !i32 {
    var result = try hyperlight.guest.call(i32, "HostDouble", .{value});
    defer result.deinit();
    return try result.value();
}

fn callHostString() !u64 {
    var result = try hyperlight.guest.call(
        u64,
        "HostStringLength",
        .{hyperlight.string("hello")},
    );
    defer result.deinit();
    return try result.value();
}

fn greeting() hyperlight.String {
    return hyperlight.string("hello from Zig");
}

fn echoBytes(value: hyperlight.Bytes) hyperlight.Bytes {
    return value;
}

fn echoByteChunks(value: hyperlight.ByteChunks) hyperlight.ByteChunks {
    return value;
}

fn noOp() void {}

comptime {
    hyperlight.guest.exportFunctions(.{
        .Add = add,
        .CallHost = callHost,
        .CallHostString = callHostString,
        .Greeting = greeting,
        .EchoBytes = echoBytes,
        .EchoByteChunks = echoByteChunks,
        .NoOp = noOp,
    });
}
