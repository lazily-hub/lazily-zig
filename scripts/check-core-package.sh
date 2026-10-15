#!/bin/sh
set -eu

for path in build.zig build.zig.zon LICENSE NOTICE README.md src/core.zig; do
    if [ ! -f "$path" ]; then
        printf 'missing package content: %s\n' "$path" >&2
        exit 1
    fi
done

# `src` is the package-manager inclusion boundary, so the focused facade is
# shipped without enumerating every source file in build.zig.zon.
if ! grep -Eq '^[[:space:]]*"src",[[:space:]]*$' build.zig.zon; then
    printf 'build.zig.zon does not include the src package tree\n' >&2
    exit 1
fi

if ! grep -Fq 'b.addModule("lazily_core"' build.zig; then
    printf 'build.zig does not export the lazily_core module\n' >&2
    exit 1
fi

printf 'core package content OK\n'
