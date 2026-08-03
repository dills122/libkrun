#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/../../.." && pwd)
lib_source="$repo_dir/src/libkrun/src/lib.rs"
block_source="$repo_dir/src/devices/src/virtio/block/device.rs"
init_source="$repo_dir/src/init_blob/init/init.c"
header="$repo_dir/include/libkrun.h"

api_body=$(awk '/fn krun_add_read_only_raw_root_fd/ { capture = 1 } capture { print } capture && /^}$/ { exit }' "$lib_source")
constructor_body=$(awk '/pub fn new_read_only_raw_file/ { capture = 1 } /fn validate_read_only_raw_file/ { exit } capture { print }' "$block_source")
validation_body=$(awk '/fn validate_read_only_raw_file/ { capture = 1 } /fn from_storage/ { exit } capture { print }' "$block_source")
root_body=$(awk '/fn get_kernel_prolog/ { capture = 1 } /fn set_env/ { exit } capture { print }' "$lib_source")

printf '%s\n' "$api_body" | grep -q 'F_DUPFD_CLOEXEC'
printf '%s\n' "$api_body" | grep -q 'File::from_raw_fd'
printf '%s\n' "$constructor_body" | grep -q 'ImagoFile::try_from'
if printf '%s\n' "$constructor_body" | grep -Eq 'filename|OpenOptions|PathBuf'; then
    printf 'raw-root constructor regained pathname authority\n' >&2
    exit 1
fi
printf '%s\n' "$validation_body" | grep -q 'O_ACCMODE != libc::O_RDONLY'
printf '%s\n' "$validation_body" | grep -q 'st_nlink() != 0'
printf '%s\n' "$validation_body" | grep -q 'st_mode() & 0o7777 != 0o400'
printf '%s\n' "$validation_body" | grep -q 'is_multiple_of(SECTOR_SIZE)'
printf '%s\n' "$root_body" | grep -q 'root=/dev/vda rootfstype=ext4 ro rootwait'
printf '%s\n' "$root_body" | grep -q 'init={BLOCK_ROOT_INIT_PATH} KRUN_DIRECT_BLOCK_ROOT=1'
if printf '%s\n' "$root_body" | grep -Eq 'add_fs_device|NullFs'; then
    printf 'governed direct-root route regained NullFs authority\n' >&2
    exit 1
fi
grep -q 'MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV' "$init_source"
grep -q 'strcmp(krun_root_options, "ro,nosuid,nodev") == 0' "$init_source"
grep -q 'int32_t krun_add_read_only_raw_root_fd' "$header"

task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/libkrun-capsule-header.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM
cc -std=c11 -Wall -Wextra -Werror -Wno-comment -I"$repo_dir/include" -fsyntax-only "$script_dir/fd-header-contract.c"

printf 'directRootSourceContract=PASS\n'
printf 'rawFdSourceContract=PASS\n'
printf 'rawFdHeaderContract=PASS\n'
printf 'pathAuthorityAdded=NO\n'
printf 'guestExecution=NOT_RUN\n'
