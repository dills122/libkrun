#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
governance_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH='' cd -- "$governance_dir/../.." && pwd)
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/libkrun-capsule-mutations.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM
source_copy="$task_tmp/libkrun"
target_dir="$task_tmp/target"
mkdir -p "$source_copy"
git -C "$repo_dir" archive HEAD | tar -x -C "$source_copy"

device_source="$source_copy/src/devices/src/virtio/block/device.rs"
api_source="$source_copy/src/libkrun/src/lib.rs"

run_device_tests_expect_failure() {
    label=$1
    log="$task_tmp/$label.log"
    if (
        cd "$source_copy"
        CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir" \
            cargo test --locked --offline -p krun-devices --lib --features blk \
            read_only_raw_fd_tests
    ) >"$log" 2>&1; then
        printf 'mutation unexpectedly passed: %s\n' "$label" >&2
        exit 1
    fi
    grep -Eq 'FAILED|test result: FAILED' "$log"
    printf 'mutation=%s result=CAUGHT detector=raw-fd-tests\n' "$label"
}

cp "$device_source" "$task_tmp/device.clean"
perl -0pi -e 's/let file = ImagoFile::try_from\(io_file\)\?;/let file = ImagoFile::open_sync(StorageOpenOptions::new().filename("\/dev\/null"))?;/' "$device_source"
if awk '/pub fn new_read_only_raw_file/ { capture = 1 } /fn validate_read_only_raw_file/ { exit } capture { print }' "$device_source" | grep -Eq 'filename|OpenOptions|PathBuf'; then
    printf 'mutation=pathname-fallback result=CAUGHT detector=source-route-audit\n'
else
    printf 'pathname mutation escaped route audit\n' >&2
    exit 1
fi
cp "$task_tmp/device.clean" "$device_source"

perl -0pi -e 's/flags & libc::O_ACCMODE != libc::O_RDONLY/false/' "$device_source"
run_device_tests_expect_failure writable-descriptor-acceptance
cp "$task_tmp/device.clean" "$device_source"

perl -0pi -e 's/let io_file = file\.try_clone\(\)\?;/let io_file = OpenOptions::new().read(true).open("\/dev\/null")?;/' "$device_source"
run_device_tests_expect_failure wrong-object-duplication
cp "$task_tmp/device.clean" "$device_source"

perl -0pi -e 's/use std::io::\{self, Write\};/use std::io::{self, Read, Write};/; s/let io_file = file\.try_clone\(\)\?;/let mut io_file = file.try_clone()?; let mut byte = [0u8; 1]; io_file.read_exact(&mut byte)?;/' "$device_source"
run_device_tests_expect_failure shared-offset-io
cp "$task_tmp/device.clean" "$device_source"

cp "$api_source" "$task_tmp/api.clean"
perl -0pi -e 's/let owned_fd = unsafe \{ libc::fcntl\(fd, libc::F_DUPFD_CLOEXEC, 3\) \};/let owned_fd = fd;/' "$api_source"
if awk '/fn krun_add_read_only_raw_root_fd/ { capture = 1 } capture { print } capture && /^}$/ { exit }' "$api_source" | grep -q 'F_DUPFD_CLOEXEC'; then
    printf 'caller-lifetime mutation escaped API audit\n' >&2
    exit 1
else
    printf 'mutation=caller-close-lifetime result=CAUGHT detector=source-route-audit\n'
fi
cp "$task_tmp/api.clean" "$api_source"

run_console_mutation() {
    mutation_name=$1
    test_name=$2
    mutation_file="$governance_dir/mutations/$mutation_name.patch"
    mutation_log="$task_tmp/$mutation_name.log"
    patch -d "$source_copy" -p1 --batch --forward <"$mutation_file" >/dev/null
    if (
        cd "$source_copy"
        CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$target_dir" \
            cargo test --locked --offline -p krun-devices --lib "$test_name" -- --exact
    ) >"$mutation_log" 2>&1; then
        printf 'restoration mutation unexpectedly survived: %s\n' "$mutation_name" >&2
        sed -n '1,160p' "$mutation_log" >&2
        exit 1
    fi
    patch -d "$source_copy" -p1 --batch --reverse <"$mutation_file" >/dev/null
    printf 'mutation=%s result=CAUGHT detector=console-test\n' "$mutation_name"
}

run_console_mutation restore-malformed-control-acceptance \
    virtio::console::device::tests::control_descriptor_requires_one_exact_readable_object
run_console_mutation restore-unchecked-port-id \
    virtio::console::device::tests::port_index_rejects_unknown_identifiers
run_console_mutation restore-duplicate-start \
    virtio::console::device::tests::repeated_or_active_port_start_is_not_scheduled_twice
run_console_mutation restore-stop-blind-output-wait \
    virtio::console::port_io::output_wait_tests::shutdown_interrupts_a_blocked_output_wait

printf 'rawFdMutationsCaught=5\n'
printf 'consoleRestorationMutationsCaught=4\n'
printf 'guestExecution=NOT_RUN\n'
