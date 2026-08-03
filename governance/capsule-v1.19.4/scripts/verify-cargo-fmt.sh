#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
governance_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH='' cd -- "$governance_dir/../.." && pwd)
format_toolchain=1.97.1
expected="$governance_dir/expected/cargo-fmt-1.97.1.txt"
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/libkrun-capsule-fmt.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM
raw="$task_tmp/raw.txt"
normalized="$task_tmp/normalized.txt"

if cargo +"$format_toolchain" fmt --manifest-path "$repo_dir/Cargo.toml" --all -- --check >"$raw" 2>&1; then
    printf 'expected retained P0-2 formatting drift was not reported\n' >&2
    exit 1
fi
sed -E \
    -e 's#^Diff in .*/src/libkrun/src/lib.rs:2468:#Diff in src/libkrun/src/lib.rs:2468:#' \
    -e 's/^[[:space:]]+$//' \
    "$raw" >"$normalized"
if ! cmp -s "$expected" "$normalized"; then
    printf 'cargo fmt reported an ungoverned formatting difference\n' >&2
    diff -u "$expected" "$normalized" >&2 || true
    exit 1
fi

printf 'cargoFmtToolchain=%s\n' "$format_toolchain"
printf 'cargoFmtExactRetainedDrift=PASS\n'
printf 'cargoFmtAdditionalDifferences=0\n'
