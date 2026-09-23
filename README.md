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

Host development requires Zig 0.16.0 and Rust 1.94.0. Host builds are native:
Zig's `-Dtarget` does not cross-compile the Rust bridge.

### Linux (KVM)

Install Clang/LLVM, `ld.lld`, and `just`. Running the examples requires access
to `/dev/kvm`. On x86_64 Linux, build and test with:

```console
zig build check
```

Runnable guest examples also require `cargo-hyperlight` 0.1.14 and a
target-compatible guest C API archive. Keep the existing x86_64 workflow:

```console
git clone https://github.com/cataggar/hyperlight hyperlight
git -C hyperlight checkout 89792856686085ddb12b11b395a1d543ccd8fb07
git -C hyperlight submodule update --init --recursive
cargo install --locked --version 0.1.14 cargo-hyperlight
(cd hyperlight/src/hyperlight_guest_capi && cargo hyperlight build --release)

zig build install \
  -Dguest-capi="$PWD/hyperlight/target/x86_64-hyperlight-none/release/libhyperlight_guest_capi.a"
zig-out/bin/hello-host zig-out/bin/hello-guest
zig-out/bin/counter-host zig-out/bin/counter-guest
```

The interoperability host accepts existing Hyperlight C and Rust guests that
export `Echo`; Linux/KVM CI exercises both.

### Apple Silicon macOS (Hypervisor.framework)

Only native arm64 macOS is supported; Intel macOS and Rosetta-host execution
are not. Use physical Apple Silicon with hypervisor support, Xcode and its
macOS SDK (`xcrun`, `codesign`), Zig 0.16.0, Homebrew LLVM/LLD and `just`:

```console
uname -m                    # arm64
sysctl kern.hv_support      # 1
xcrun --show-sdk-path
brew install llvm lld just
rustup toolchain install 1.94.0 --profile minimal --component rustfmt
export RUSTUP_TOOLCHAIN=1.94.0
export LIBCLANG_PATH="$(brew --prefix llvm)/lib"
export PATH="$(brew --prefix llvm)/bin:$(brew --prefix lld)/bin:$PATH"
just fmt-check
zig build check --summary all
```

`RUSTUP_TOOLCHAIN` selects Rust only for this shell; no global Rust default
change is needed. The host build selects Hyperlight's HVF feature and links
`Hypervisor.framework`. `zig build check` runs signed Zig and Rust bridge
tests, ABI/version checks, and guest object compilation without launching a
sandbox. To build runnable AArch64 guests, use the pinned fork and its
submodules:

```console
git clone https://github.com/cataggar/hyperlight hyperlight
git -C hyperlight checkout 89792856686085ddb12b11b395a1d543ccd8fb07
git -C hyperlight submodule update --init --recursive
cargo install --locked --version 0.1.14 cargo-hyperlight
(cd hyperlight/src/hyperlight_guest_capi && \
  HYPERLIGHT_GUEST_clang="$(brew --prefix llvm)/bin/clang" \
  AR="$(brew --prefix llvm)/bin/llvm-ar" cargo hyperlight build --release)
```

The archive is
`hyperlight/target/aarch64-hyperlight-none/release/libhyperlight_guest_capi.a`.
It contains **AArch64 ELF** objects; host executables are **arm64 Mach-O**.
Build the fork's C `simpleguest` with LLVM's ELF-capable tools:

```console
(
  cd hyperlight
  mkdir -p src/tests/c_guests/c_simpleguest/out/release
  clang -c -nostdlibinc --target=aarch64-unknown-linux-none \
    -fno-stack-protector -fstack-clash-protection -mstack-probe-size=4096 \
    -fPIC -O3 src/tests/c_guests/c_simpleguest/main.c \
    -I src/hyperlight_guest_capi/include \
    -I src/hyperlight_libc/third_party/picolibc/libc/include \
    -I src/hyperlight_libc/third_party/picolibc/libc/stdio \
    -I src/hyperlight_libc/include \
    -o src/tests/c_guests/c_simpleguest/out/release/main.o
  ld.lld --entry entrypoint --nostdlib -pie --no-dynamic-linker \
    -o src/tests/c_guests/c_simpleguest/out/release/simpleguest \
    src/tests/c_guests/c_simpleguest/out/release/main.o \
    -L target/aarch64-hyperlight-none/release -l hyperlight_guest_capi
)
(cd hyperlight/src/tests/rust_guests && \
  HYPERLIGHT_GUEST_clang="$(brew --prefix llvm)/bin/clang" \
  AR="$(brew --prefix llvm)/bin/llvm-ar" \
  cargo hyperlight build -p simpleguest --release)
```

Link and install the Zig guests (also AArch64 ELF), then run each host as a
separate signed process:

```console
zig build install \
  -Dguest-capi="$PWD/hyperlight/target/aarch64-hyperlight-none/release/libhyperlight_guest_capi.a"
just hello
just counter
just interoperability "$PWD/hyperlight/src/tests/c_guests/c_simpleguest/out/release/simpleguest"
just interoperability "$PWD/hyperlight/src/tests/rust_guests/target/aarch64-hyperlight-none/release/simpleguest"

# Builds/installs and runs all four scenarios, failing if any artifact is missing:
just runtime-check \
  "$PWD/hyperlight/target/aarch64-hyperlight-none/release/libhyperlight_guest_capi.a" \
  "$PWD/hyperlight/src/tests/c_guests/c_simpleguest/out/release/simpleguest" \
  "$PWD/hyperlight/src/tests/rust_guests/target/aarch64-hyperlight-none/release/simpleguest"
```

`tools/run-host.sh` ad-hoc signs each macOS host executable **after** it is
built, using only `com.apple.security.hypervisor` from
`tools/macos-entitlements.plist`. The `just` recipes and `zig build check`
sign automatically; if launching a host executable directly, sign it again
after every rebuild with `tools/run-host.sh --sign-only <host-executable>`.
Local execution needs neither a Developer ID certificate nor notarization;
never sign the guest ELF files. HVF currently uses one VM/address space per
process, so this workflow does not guarantee multiple sandboxes in a single
process. vCPUs are thread-local; keep each sandbox on one host thread for
this workflow, since moving it requires synchronization. macOS runtime
acceptance is performed locally on physical hardware, not in CI.
