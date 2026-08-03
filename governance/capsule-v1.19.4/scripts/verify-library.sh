#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
governance_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH='' cd -- "$governance_dir/../.." && pwd)
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/libkrun-capsule-library.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM
target_dir="$task_tmp/target"

if [ "${CAPSULE_ALLOW_GUEST:-0}" != 0 ]; then
    printf 'guest execution is outside this governed verification route\n' >&2
    exit 2
fi

(
    cd "$repo_dir"
    rustfmt --edition 2021 --check \
        src/devices/src/virtio/console/device.rs \
        src/devices/src/virtio/console/port.rs \
        src/devices/src/virtio/console/port_io.rs \
        src/devices/src/virtio/console/process_tx.rs
)
"$script_dir/verify-cargo-fmt.sh"

(
    cd "$repo_dir"
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/check" \
        cargo check --locked --offline -p krun-devices --all-targets --features blk
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/check-libkrun" \
        cargo check --locked --offline -p libkrun --lib --no-default-features --features blk
)

default_log="$task_tmp/default-tests.log"
(
    cd "$repo_dir"
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/tests" \
        cargo test --locked --offline -p krun-devices --lib
) | tee "$default_log"
grep -Eq 'test result: ok\. 51 passed; 0 failed' "$default_log"

bounded_console_log="$task_tmp/bounded-console-tests.log"
(
    cd "$repo_dir"
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/tests" \
        cargo test --locked --offline -p krun-devices --lib \
        virtio::console::coverage_tests -- --ignored --test-threads=1
) | tee "$bounded_console_log"
grep -Eq 'test result: ok\. 4 passed; 0 failed' "$bounded_console_log"

blk_log="$task_tmp/blk-tests.log"
(
    cd "$repo_dir"
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/tests-blk" \
        cargo test --locked --offline -p krun-devices --lib --features blk -- \
        --test-threads=1
) | tee "$blk_log"
grep -Eq 'test result: ok\. 53 passed; 0 failed' "$blk_log"

raw_fd_log="$task_tmp/raw-fd-tests.log"
(
    cd "$repo_dir"
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/tests-libkrun" \
        cargo test --locked --offline -p libkrun --test governed_fd \
        --no-default-features --features blk -- --test-threads=1
) | tee "$raw_fd_log"
grep -Eq 'test result: ok\. 2 passed; 0 failed' "$raw_fd_log"

(
    cd "$repo_dir"
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/clippy" \
        cargo clippy --locked --offline -p krun-devices --lib --features blk --no-deps -- \
        -D warnings -A deprecated
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/clippy-libkrun" \
        cargo clippy --locked --offline -p libkrun --lib --no-default-features --features blk --no-deps -- \
        -D warnings
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/clippy-libkrun-tests" \
        cargo clippy --locked --offline -p libkrun --test governed_fd \
        --no-default-features --features blk --no-deps -- -D warnings
)

repeat=1
while [ "$repeat" -le 25 ]; do
    (
        cd "$repo_dir"
        CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/tests" \
            cargo test --locked --offline -p krun-devices --lib \
            virtio::console::port_io::output_wait_tests::shutdown_interrupts_a_blocked_output_wait \
            -- --exact >/dev/null 2>&1
    )
    repeat=$((repeat + 1))
done

repeat=1
while [ "$repeat" -le 25 ]; do
    (
        cd "$repo_dir"
        CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/tests" \
            cargo test --locked --offline -p krun-devices --lib \
            virtio::console::coverage_tests::shutdown_cancels_a_queued_backpressured_write \
            -- --exact --ignored --test-threads=1 >/dev/null 2>&1
    )
    repeat=$((repeat + 1))
done

coverage_raw="$task_tmp/coverage.json"
coverage_summary="$task_tmp/coverage-summary.json"
(
    cd "$repo_dir"
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir/coverage" \
        cargo llvm-cov --locked --offline -p krun-devices --lib \
        --json --output-path "$coverage_raw" -- --include-ignored --test-threads=1
)
python3 "$script_dir/summarize-coverage.py" "$coverage_raw" "$coverage_summary"
if [ -n "${CAPSULE_COVERAGE_OUTPUT:-}" ]; then
    cp "$coverage_summary" "$CAPSULE_COVERAGE_OUTPUT"
fi

asan_status=UNSUPPORTED
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    sanitizer_toolchain=nightly-2026-05-28
    (
        cd "$repo_dir"
        CARGO_NET_OFFLINE=true \
            CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS=-Zsanitizer=address \
            CARGO_TARGET_DIR="$target_dir/asan" \
            cargo +"$sanitizer_toolchain" test --locked --target aarch64-apple-darwin \
            --offline -p krun-devices --lib
        CARGO_NET_OFFLINE=true \
            CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS=-Zsanitizer=address \
            CARGO_TARGET_DIR="$target_dir/asan" \
            cargo +"$sanitizer_toolchain" test --locked --target aarch64-apple-darwin \
            --offline -p krun-devices --lib virtio::console::coverage_tests -- \
            --ignored --test-threads=1
        CARGO_NET_OFFLINE=true \
            CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS=-Zsanitizer=address \
            CARGO_TARGET_DIR="$target_dir/asan-libkrun" \
            cargo +"$sanitizer_toolchain" test --locked --target aarch64-apple-darwin \
            --offline -p libkrun --test governed_fd --no-default-features --features blk -- \
            --test-threads=1
    )
    asan_status=PASS
fi

printf 'governedConsoleRustfmt=PASS\n'
printf 'cargoFmt=PASS_EXACT_RETAINED_DRIFT_ONLY\n'
printf 'cargoCheck=PASS\n'
printf 'consoleCorpusTests=51\n'
printf 'boundedConsoleCoverageTests=4\n'
printf 'blockFeatureTests=53\n'
printf 'rawFdContractTests=2\n'
printf 'rawFdLibraryBoundaryTests=2\n'
printf 'clippyWarningsDenied=PASS\n'
printf 'clippyAllowance=deprecated-GuestMemory-try_access-only\n'
printf 'shutdownRepetitions=25\n'
printf 'queuedBackpressureShutdownRepetitions=25\n'
printf 'addressSanitizer=%s\n' "$asan_status"
cat "$coverage_summary"
printf 'guestExecution=NOT_RUN\n'
