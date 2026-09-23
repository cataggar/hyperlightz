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
    tools/run-host.sh zig-out/bin/hello-host {{quote(guest)}}

counter guest="zig-out/bin/counter-guest":
    tools/run-host.sh zig-out/bin/counter-host {{quote(guest)}}

interoperability guest:
    tools/run-host.sh zig-out/bin/interoperability-host {{quote(guest)}}

runtime-check guest_capi c_guest rust_guest:
    test -f {{quote(guest_capi)}} || { printf 'missing guest C API archive: %s\n' {{quote(guest_capi)}} >&2; exit 1; }
    test -f {{quote(c_guest)}} || { printf 'missing C guest: %s\n' {{quote(c_guest)}} >&2; exit 1; }
    test -f {{quote(rust_guest)}} || { printf 'missing Rust guest: %s\n' {{quote(rust_guest)}} >&2; exit 1; }
    zig build install -Dguest-capi={{quote(guest_capi)}} --summary all
    tools/run-host.sh zig-out/bin/hello-host zig-out/bin/hello-guest
    tools/run-host.sh zig-out/bin/counter-host zig-out/bin/counter-guest
    tools/run-host.sh zig-out/bin/interoperability-host {{quote(c_guest)}}
    tools/run-host.sh zig-out/bin/interoperability-host {{quote(rust_guest)}}
