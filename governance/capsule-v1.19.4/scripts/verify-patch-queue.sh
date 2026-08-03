#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
governance_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH='' cd -- "$governance_dir/../.." && pwd)
upstream_commit=728df8125077d0db44265f6e997c72b81b65c015
governed_base_commit=4ea8d1de861ed1c0636fc800b6da8fb71a086aa5
patch_set_sha256=d19fd0ff159c699acccda2621519de45a09408bf3847b418ac34e02b79e805d5

patches='0001-pin-libkrunfw-rpath.patch
0002-read-only-block-root-mount-flags.patch
0003-direct-block-root.patch
0004-read-only-raw-root-fd.patch
0005-console-correctness.patch'
governed_paths='include/libkrun.h
src/devices/src/virtio/block/device.rs
src/devices/src/virtio/console/device.rs
src/devices/src/virtio/console/port.rs
src/devices/src/virtio/console/port_io.rs
src/devices/src/virtio/console/process_tx.rs
src/init_blob/init/init.c
src/libkrun/src/lib.rs
src/vmm/src/resources.rs
src/vmm/src/vmm_config/block.rs'

expected_hash_for() {
    case "$1" in
        0001-pin-libkrunfw-rpath.patch) printf '%s\n' a845cce3cd479a73c6a698164dc1b466e8d67796018b107077504478e0ec9cd5 ;;
        0002-read-only-block-root-mount-flags.patch) printf '%s\n' b2120d4cc848e138a28165906d6c5cc4da1efee8004e392a7ddddc2334136823 ;;
        0003-direct-block-root.patch) printf '%s\n' 642d9e196cbb752347e06a8ce4ca35ea38ef94bf7e15ca9e1b136ed58229ef59 ;;
        0004-read-only-raw-root-fd.patch) printf '%s\n' 48cdbc307b3fa1209fa0ec68fc3f817634af312983d68f0de259db86c0b43333 ;;
        0005-console-correctness.patch) printf '%s\n' 584ce48548fe969684fe3c55e57fbf56e7dae40af28c241c24c47b138faf1283 ;;
        *) printf 'unknown governed patch: %s\n' "$1" >&2; exit 2 ;;
    esac
}

git -C "$repo_dir" cat-file -e "$upstream_commit^{commit}"
git -C "$repo_dir" cat-file -e "$governed_base_commit^{commit}"
actual_base=$(git -C "$repo_dir" rev-parse --verify refs/heads/capsule/upstream-v1.19.4 2>/dev/null || git -C "$repo_dir" rev-parse --verify refs/remotes/origin/capsule/upstream-v1.19.4)
[ "$actual_base" = "$governed_base_commit" ] || {
    printf 'governed baseline branch moved: got %s, want %s\n' "$actual_base" "$governed_base_commit" >&2
    exit 1
}

task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/libkrun-capsule-patches.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM
reconstructed="$task_tmp/reconstructed"
mkdir -p "$reconstructed"
git -C "$repo_dir" archive "$upstream_commit" | tar -x -C "$reconstructed"

identity_file="$task_tmp/identities"
: >"$identity_file"
order=1
for patch_name in $patches; do
    expected_hash=$(expected_hash_for "$patch_name")
    patch_file="$governance_dir/patches/$patch_name"
    actual_hash=$(shasum -a 256 "$patch_file" | awk '{print $1}')
    [ "$actual_hash" = "$expected_hash" ] || {
        printf 'patch identity mismatch: %s got %s want %s\n' "$patch_name" "$actual_hash" "$expected_hash" >&2
        exit 1
    }
    printf '%04d:%s\n' "$order" "$actual_hash" >>"$identity_file"
    patch -d "$reconstructed" -p1 --batch --forward <"$patch_file" >/dev/null
    printf 'patch[%04d]=%s sha256=%s\n' "$order" "$patch_name" "$actual_hash"
    order=$((order + 1))
done
actual_patch_set=$(shasum -a 256 "$identity_file" | awk '{print $1}')
[ "$actual_patch_set" = "$patch_set_sha256" ] || {
    printf 'patch-set identity mismatch: got %s want %s\n' "$actual_patch_set" "$patch_set_sha256" >&2
    exit 1
}

for governed_path in $governed_paths; do
    governed_base_path="$task_tmp/governed-base"
    git -C "$repo_dir" show "$governed_base_commit:$governed_path" >"$governed_base_path"
    cmp "$reconstructed/$governed_path" "$governed_base_path"
done

for patch_name in \
    0005-console-correctness.patch \
    0004-read-only-raw-root-fd.patch \
    0003-direct-block-root.patch \
    0002-read-only-block-root-mount-flags.patch \
    0001-pin-libkrunfw-rpath.patch; do
    patch -d "$reconstructed" -p1 --batch --reverse --dry-run <"$governance_dir/patches/$patch_name" >/dev/null
done

printf 'upstreamCommit=%s\n' "$upstream_commit"
printf 'governedBaseCommit=%s\n' "$governed_base_commit"
printf 'patchSetSha256=%s\n' "$actual_patch_set"
printf 'cleanReconstruction=PASS\n'
printf 'reverseDryRun=PASS\n'
printf 'guestExecution=NOT_RUN\n'
