#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
"$script_dir/verify-patch-queue.sh"
"$script_dir/audit-governed-source.sh"
status=0
if ! "$script_dir/verify-library.sh"; then
    status=1
fi
if ! "$script_dir/verify-mutations.sh"; then
    status=1
fi
if ! "$script_dir/verify-default-init.sh"; then
    status=1
fi
if [ "$status" -eq 0 ]; then
    printf 'governedLibraryValidation=PASS\n'
else
    printf 'governedLibraryValidation=BLOCKED\n'
fi
printf 'backendAdmission=NOT_PERFORMED\n'
printf 'guestExecution=NOT_RUN\n'
exit "$status"
