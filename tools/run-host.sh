#!/bin/sh
set -eu

mode=run
if [ "${1:-}" = "--sign-only" ]; then
    mode=sign
    shift
fi

if [ "$#" -eq 0 ] || [ -z "$1" ]; then
    printf 'usage: %s [--sign-only] executable [arguments...]\n' "$0" >&2
    exit 2
fi
if [ "$mode" = sign ] && [ "$#" -ne 1 ]; then
    printf '%s: --sign-only takes exactly one executable\n' "$0" >&2
    exit 2
fi

case "$(uname -s)" in
    Darwin)
        if [ "$(uname -m)" != arm64 ]; then
            printf '%s: Intel macOS is unsupported; use Apple Silicon\n' "$0" >&2
            exit 2
        fi
        script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        codesign --force --sign - --entitlements "$script_dir/macos-entitlements.plist" "$1"
        ;;
    Linux) ;;
    *)
        printf '%s: unsupported host operating system\n' "$0" >&2
        exit 2
        ;;
esac

if [ "$mode" = sign ]; then
    exit 0
fi
exec "$@"
