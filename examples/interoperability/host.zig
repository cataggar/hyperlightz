const std = @import("std");
const hyperlight = @import("hyperlight");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedGuestPath;

    var builder = try hyperlight.host.Builder.initFromFile(init.arena.allocator(), args[1]);
    defer builder.deinit();
    var sandbox = try builder.build();
    defer sandbox.deinit();

    var result = try sandbox.call(
        hyperlight.String,
        "Echo",
        .{hyperlight.string("Zig host interoperability")},
    );
    defer result.deinit();
    if (!std.mem.eql(u8, result.bytes, "Zig host interoperability")) {
        return error.UnexpectedResult;
    }
}
