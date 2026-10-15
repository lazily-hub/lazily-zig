#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
zig_bin=${ZIG:-zig}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

(cd "$root" && tar -cf "$tmp/lazily-zig.tar" build.zig build.zig.zon src LICENSE NOTICE README.md)
mkdir -p "$tmp/lazily"
tar -xf "$tmp/lazily-zig.tar" -C "$tmp/lazily"
mkdir -p "$tmp/consumer/src"
cp "$root/tests/core-artifact-consumer/build.zig" "$tmp/consumer/"
cp "$root/tests/core-artifact-consumer/build.zig.zon" "$tmp/consumer/"
cp "$root/tests/core-artifact-consumer/src/main.zig" "$tmp/consumer/src/"
sed -i "s|__ARTIFACT__|../lazily|" "$tmp/consumer/build.zig.zon"

(cd "$tmp/consumer" && "$zig_bin" build run)
if grep -R -F "$root" "$tmp/consumer/.zig-cache" "$tmp/consumer/zig-cache" >/dev/null 2>&1; then
  echo "consumer metadata references the source checkout" >&2
  exit 1
fi
