const std = @import("std");

const zig_version = "0.16.0";
const hyperlight_revision = "643938e4741c1c7049386d1800013c21cdf617e4";

const Check = struct {
    path: []const u8,
    expected: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const checks = [_]Check{
        .{ .path = "build.zig.zon", .expected = ".minimum_zig_version = \"" ++ zig_version ++ "\"" },
        .{ .path = ".github/workflows/ci.yml", .expected = "cataggar/zig@v" ++ zig_version },
        .{ .path = "bridge/Cargo.toml", .expected = "rev = \"" ++ hyperlight_revision ++ "\"" },
        .{ .path = ".github/workflows/ci.yml", .expected = "ref: " ++ hyperlight_revision },
    };

    for (checks) |check| {
        const contents = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            check.path,
            init.arena.allocator(),
            .limited(1024 * 1024),
        );
        if (std.mem.indexOf(u8, contents, check.expected) == null) {
            std.log.err("{s} does not contain pinned value: {s}", .{
                check.path,
                check.expected,
            });
            return error.InconsistentVersion;
        }
    }
}
