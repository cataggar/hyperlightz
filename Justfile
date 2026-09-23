set positional-arguments

check:
    zig build check --summary all

fmt:
    zig fmt build.zig src examples tools
    cargo fmt --manifest-path bridge/Cargo.toml

fmt-check:
    zig fmt --check build.zig src examples tools
    cargo fmt --manifest-path bridge/Cargo.toml -- --check

guest-check:
    zig build guest-check --summary all

examples guest_capi:
    zig build install -Dguest-capi={{guest_capi}} --summary all

hello guest="zig-out/bin/hello-guest":
    zig-out/bin/hello-host {{guest}}

counter guest="zig-out/bin/counter-guest":
    zig-out/bin/counter-host {{guest}}
