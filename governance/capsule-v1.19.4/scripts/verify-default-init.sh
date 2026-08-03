#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
governance_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH='' cd -- "$governance_dir/../.." && pwd)
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/libkrun-capsule-default-init.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM

if [ "${CAPSULE_ALLOW_GUEST:-0}" != 0 ]; then
    printf 'guest execution is outside this governed verification route\n' >&2
    exit 2
fi

case "$(uname -s)" in
    Darwin)
        sysroot=${SYSROOT_LINUX:-$repo_dir/linux-sysroot}
        if [ ! -f "$sysroot/.sysroot_ready" ]; then
            printf 'defaultInitBlobBuild=BLOCKED\n'
            printf 'defaultInitBlobReason=exact Linux sysroot is unavailable for the no-network macOS cross-build\n'
            printf 'defaultInitBlobSysroot=%s\n' "$sysroot"
            printf 'guestExecution=NOT_RUN\n'
            exit 1
        fi
        arch=$(uname -m | sed 's/^arm64$/aarch64/')
        gcc_triplet="$arch-linux-gnu"
        gcc_version=${GCC_VERSION:-12}
        gcc_lib_dir="$sysroot/usr/lib/gcc/$gcc_triplet/$gcc_version"
        if [ ! -d "$gcc_lib_dir" ] || ! command -v /usr/bin/clang >/dev/null 2>&1 || ! command -v ld.lld >/dev/null 2>&1; then
            printf 'defaultInitBlobBuild=BLOCKED\n'
            printf 'defaultInitBlobReason=exact clang-lld Linux cross-toolchain is unavailable\n'
            printf 'guestExecution=NOT_RUN\n'
            exit 1
        fi
        cc_linux="/usr/bin/clang -target $gcc_triplet -fuse-ld=lld -Wl,-strip-debug --sysroot $sysroot -B$gcc_lib_dir -L$gcc_lib_dir -Wno-c23-extensions"
        ;;
    Linux)
        cc_linux=${CC_LINUX:-${CC:-cc}}
        ;;
    *)
        printf 'defaultInitBlobBuild=BLOCKED\n'
        printf 'defaultInitBlobReason=unsupported host for the upstream Linux default-init build route\n'
        printf 'guestExecution=NOT_RUN\n'
        exit 1
        ;;
esac

(
    cd "$repo_dir"
    CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$task_tmp/target" CC_LINUX="$cc_linux" \
        cargo build --locked --offline -p libkrun --lib --features blk
)

printf 'defaultInitBlobBuild=PASS\n'
printf 'defaultInitBlobNetwork=DISABLED\n'
printf 'guestExecution=NOT_RUN\n'
