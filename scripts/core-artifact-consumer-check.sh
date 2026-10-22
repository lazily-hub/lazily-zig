#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
zig_bin=${ZIG:-zig}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/lazily"
if [ -n "${LAZILY_CORE_ARTIFACT_VERSION:-}" ]; then
  : "${LAZILY_CORE_ARTIFACT_SHA256:?LAZILY_CORE_ARTIFACT_SHA256 is required for a published source archive}"
  archive="$tmp/lazily-zig-v$LAZILY_CORE_ARTIFACT_VERSION.tar.gz"
  curl --fail --location --silent --show-error \
    "https://github.com/lazily-hub/lazily-zig/archive/refs/tags/v$LAZILY_CORE_ARTIFACT_VERSION.tar.gz" \
    --output "$archive"
  printf '%s  %s\n' "$LAZILY_CORE_ARTIFACT_SHA256" "$archive" | sha256sum --check --status
  tar -xzf "$archive" --strip-components=1 -C "$tmp/lazily"
else
  (cd "$root" && tar -cf "$tmp/lazily-zig.tar" build.zig build.zig.zon src LICENSE NOTICE README.md)
  tar -xf "$tmp/lazily-zig.tar" -C "$tmp/lazily"
fi
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
