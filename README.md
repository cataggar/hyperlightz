# hyperlightz

Comptime-first Zig 0.16 bindings for [Hyperlight](https://github.com/hyperlight-dev/hyperlight).
The package provides:

- a native Zig host API backed by a small Rust static bridge;
- generated guest registration and callback trampolines;
- guest-to-host calls with explicit result ownership;
- scalar, string, byte-vector, and byte-chunk wire values;
- sandbox snapshot and restore support.

The current implementation pins `cataggar/hyperlight` commit
`89792856686085ddb12b11b395a1d543ccd8fb07`, which contains the runtime-defined
host API and ownership-safe guest C API needed by these bindings.

## Host API

Function signatures and wire types are derived at compile time:

```zig
const hyperlight = @import("hyperlight");

fn double(calls: *usize, value: i32) !i32 {
    calls.* += 1;
    return value * 2;
}

var builder = try hyperlight.host.Builder.initFromFile(allocator, guest_path);
defer builder.deinit();

var calls: usize = 0;
try builder.hostFunctionWithContext("HostDouble", &calls, double);

var sandbox = try builder.build();
defer sandbox.deinit();

const answer = try sandbox.call(i32, "Add", .{ @as(i32, 20), @as(i32, 22) });
```

Use `hyperlight.String`, `hyperlight.Bytes`, and `hyperlight.ByteChunks` when
the wire representation is not implied by the Zig type. String, byte, and
byte-chunk host results are owned values and must be released with `deinit`.

## Guest API

Guest exports are generated from an anonymous struct at compile time:

```zig
const hyperlight = @import("hyperlight");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn callHost(value: i32) !i32 {
    var result = try hyperlight.guest.call(i32, "HostDouble", .{value});
    defer result.deinit();
    return try result.value();
}

comptime {
    hyperlight.guest.exportFunctions(.{
        .Add = add,
        .CallHost = callHost,
    });
}
```

`guest.call` returns a `HostResult(T)`. Its `value()` is borrowed from the
result allocation and remains valid until `deinit()`.

## Build and test

Host development requires Zig 0.16.0 and Rust 1.94:

```console
zig build check
```

Runnable guest examples additionally require Clang/LLVM,
`cargo-hyperlight` 0.1.14, and a target-compatible guest C API archive:

```console
git clone https://github.com/cataggar/hyperlight hyperlight
git -C hyperlight checkout 89792856686085ddb12b11b395a1d543ccd8fb07
cargo install --locked --version 0.1.14 cargo-hyperlight
(cd hyperlight/src/hyperlight_guest_capi && cargo hyperlight build --release)

zig build install \
  -Dguest-capi="$PWD/hyperlight/target/x86_64-hyperlight-none/release/libhyperlight_guest_capi.a"
zig-out/bin/hello-host zig-out/bin/hello-guest
zig-out/bin/counter-host zig-out/bin/counter-guest
```

Running host examples requires Linux and access to `/dev/kvm`. The
interoperability host accepts existing Hyperlight C and Rust guests that export
`Echo`; CI exercises both.
