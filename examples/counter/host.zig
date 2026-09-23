const std = @import("std");
const hyperlight = @import("hyperlight");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedGuestPath;

    var builder = try hyperlight.host.Builder.initFromFile(init.arena.allocator(), args[1]);
    defer builder.deinit();
    var sandbox = try builder.build();
    defer sandbox.deinit();

    const before_snapshot = try sandbox.call(i32, "Increment", .{@as(i32, 10)});
    var snapshot = try sandbox.snapshot();
    defer snapshot.deinit();

    const after_increment = try sandbox.call(i32, "Increment", .{@as(i32, 5)});
    try sandbox.restore(&snapshot);
    const after_restore = try sandbox.call(i32, "Get", .{});
    if (before_snapshot != 10 or after_increment != 15 or after_restore != 10) {
        return error.UnexpectedResult;
    }

    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.print(
        "counter: before snapshot={d}, after increment={d}, after restore={d}\n",
        .{ before_snapshot, after_increment, after_restore },
    );
    try stdout_writer.interface.flush();
}
