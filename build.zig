const std = @import("std");

fn linkHostBridge(
    module: *std.Build.Module,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) void {
    module.addObjectFile(b.path(".zig-cache/cargo/release/libhyperlightz_bridge.a"));
    module.link_libc = true;
    if (target.result.os.tag == .linux) {
        module.linkSystemLibrary("dl", .{});
        module.linkSystemLibrary("gcc_s", .{});
        module.linkSystemLibrary("m", .{});
        module.linkSystemLibrary("pthread", .{});
        module.linkSystemLibrary("rt", .{});
        module.linkSystemLibrary("util", .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cargo = b.option([]const u8, "cargo", "Path to Cargo") orelse "cargo";
    const guest_capi = b.option(
        []const u8,
        "guest-capi",
        "Path to a target-compatible libhyperlight_guest_capi.a",
    );
    const cargo_target_dir = b.pathFromRoot(".zig-cache/cargo");

    const module = b.addModule("hyperlight", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_bridge = b.addSystemCommand(&.{
        cargo,
        "build",
        "--locked",
        "--release",
        "--manifest-path",
        "bridge/Cargo.toml",
    });
    build_bridge.setEnvironmentVariable("CARGO_TARGET_DIR", cargo_target_dir);
    const bridge_step = b.step("bridge", "Build the Rust host bridge");
    bridge_step.dependOn(&build_bridge.step);

    const tests = b.addTest(.{ .root_module = module });
    tests.step.dependOn(&build_bridge.step);
    linkHostBridge(tests.root_module, b, target);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const test_bridge = b.addSystemCommand(&.{
        cargo,
        "test",
        "--locked",
        "--manifest-path",
        "bridge/Cargo.toml",
    });
    test_bridge.setEnvironmentVariable("CARGO_TARGET_DIR", cargo_target_dir);
    const bridge_test_step = b.step("bridge-test", "Run Rust bridge tests");
    bridge_test_step.dependOn(&test_bridge.step);

    const c_abi_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    c_abi_module.addIncludePath(b.path("bridge/include"));
    c_abi_module.addCSourceFile(.{
        .file = b.path("bridge/tests/abi.c"),
        .flags = &.{"-std=c11"},
    });
    const c_abi = b.addObject(.{
        .name = "hyperlightz-c-abi-check",
        .root_module = c_abi_module,
    });
    const abi_step = b.step("abi-check", "Check the C, Rust, and Zig ABI definitions");
    abi_step.dependOn(&c_abi.step);

    const versions_module = b.createModule(.{
        .root_source_file = b.path("tools/check_versions.zig"),
        .target = target,
        .optimize = optimize,
    });
    const versions_executable = b.addExecutable(.{
        .name = "check-versions",
        .root_module = versions_module,
    });
    const check_versions = b.addRunArtifact(versions_executable);
    const versions_step = b.step("version-check", "Check pinned tool and dependency versions");
    versions_step.dependOn(&check_versions.step);

    const host_examples_step = b.step("host-examples", "Build the host examples");
    const host_examples = .{
        .{ "hello-host", "examples/hello/host.zig" },
        .{ "counter-host", "examples/counter/host.zig" },
        .{ "interoperability-host", "examples/interoperability/host.zig" },
    };
    inline for (host_examples) |example| {
        const example_module = b.createModule(.{
            .root_source_file = b.path(example[1]),
            .target = target,
            .optimize = optimize,
        });
        example_module.addImport("hyperlight", module);
        linkHostBridge(example_module, b, target);
        const executable = b.addExecutable(.{
            .name = example[0],
            .root_module = example_module,
        });
        executable.step.dependOn(&build_bridge.step);
        host_examples_step.dependOn(&executable.step);
        b.installArtifact(executable);
    }

    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = target.result.cpu.arch,
        .os_tag = .linux,
        .abi = .none,
    });
    const guest_api = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = guest_target,
        .optimize = .ReleaseSmall,
    });
    const guest_examples_step = b.step(
        "guest-check",
        "Compile the guest examples without linking the guest C API",
    );
    const linked_guest_examples_step = b.step(
        "guest-examples",
        "Build runnable guest examples with -Dguest-capi=<archive>",
    );
    const guest_examples = .{
        .{ "hello-guest", "examples/hello/guest.zig" },
        .{ "counter-guest", "examples/counter/guest.zig" },
    };
    inline for (guest_examples) |example| {
        const example_module = b.createModule(.{
            .root_source_file = b.path(example[1]),
            .target = guest_target,
            .optimize = .ReleaseSmall,
        });
        example_module.addImport("hyperlight", guest_api);
        const object = b.addObject(.{
            .name = example[0],
            .root_module = example_module,
        });
        guest_examples_step.dependOn(&object.step);

        if (guest_capi) |archive| {
            const linked_module = b.createModule(.{
                .root_source_file = b.path(example[1]),
                .target = guest_target,
                .optimize = .ReleaseSmall,
            });
            linked_module.addImport("hyperlight", guest_api);
            linked_module.addObjectFile(.{ .cwd_relative = archive });
            const executable = b.addExecutable(.{
                .name = example[0],
                .root_module = linked_module,
            });
            executable.entry = .{ .symbol_name = "entrypoint" };
            executable.pie = true;
            linked_guest_examples_step.dependOn(&executable.step);
            b.installArtifact(executable);
        }
    }

    const check_step = b.step("check", "Build and test all host components");
    check_step.dependOn(test_step);
    check_step.dependOn(bridge_test_step);
    check_step.dependOn(abi_step);
    check_step.dependOn(versions_step);
    check_step.dependOn(host_examples_step);
    check_step.dependOn(guest_examples_step);
}
