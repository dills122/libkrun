# Capsule governed libkrun v1.19.4 patch line

This directory governs one narrowly scoped downstream patch queue over the immutable upstream libkrun v1.19.4 commit `728df8125077d0db44265f6e997c72b81b65c015`. The baseline branch is `capsule/upstream-v1.19.4`; the proposed work branch is `codex/governed-capsule-v1.19.4`.

This line is local library and source-governance evidence only. It does not admit a Capsule backend or profile, create or execute a guest, wire product code, change libkrunfw or a kernel, exercise a Supervisor, sign a release, or grant path, image, network, mount, write, or deployment authority.

## Ordered retained patches

The files in `patches/` are byte-for-byte retained Capsule evidence. `PATCH_QUEUE.json` records their source locations, SHA-256 identities, reviewed Capsule provenance, touched paths, and exact order. The queue must reconstruct the governed sources cleanly from the baseline and reverse cleanly in the opposite order.

1. Resolve libkrunfw through `@rpath`.
2. Translate immutable-root mount flags in init.
3. Remove NullFs from the governed boot path and boot the block root directly.
4. Add the raw-only, descriptor-native, read-only root API.
5. Harden directional virtio-console handling.

The first two patches are prerequisites. They remain independently hashed and are never inferred from a later patch. The API change in patch 4 is additive; existing public entry points remain present. No pathname fallback is introduced for the new raw-root route.

## Review and branch policy

The baseline branch is an immutable pointer to the exact upstream tag commit. It must never be rebased, force-pushed, or advanced. Updates use a new versioned baseline and work branch.

Changes to this line require:

- a draft pull request targeting the exact versioned baseline;
- CODEOWNER review by `@dills122` and an independent human review before merge;
- DCO sign-off and the repository's required assistance trailer on every commit;
- exact patch reconstruction plus all governed checks in `scripts/verify-governed.sh`;
- explicit resolution of the blockers below; and
- no force-push after review begins unless reviewers are told exactly what changed.

A green workflow is necessary but not sufficient for merge. The PR stays draft while any blocker remains.

## CI routing

`.github/workflows/capsule-governed.yml` runs only for the versioned governed branch, pull requests targeting the versioned baseline, manual dispatch, and changes to this exact patch line or its touched source paths. It adds no exception to upstream checks. The governed checks use fixed local fixtures and library/unit processes only; the scripts reject opt-in guest execution.

The upstream integration workflow is precisely routed away from pull requests whose base is `capsule/upstream-v1.19.4`, because it installs firmware and executes guests. All other pull requests retain upstream integration behavior. The governed replacement performs no guest execution. Governed Clippy uses the retained Rust 1.93.1 toolchain with only the documented deprecated `GuestMemory::try_access` allowance. Rust 1.97.1 formatting must report exactly the one retained P0-2 line-wrap drift recorded in `expected/cargo-fmt-1.97.1.txt`; any additional difference fails CI. The 53-test `blk` corpus runs with one test thread because two exact retained raw-FD tests use a clock-derived temporary name that can collide under parallel execution on macOS. Serial routing preserves every assertion and the exact retained source bytes. This preserves exact retained patch bytes without silently exempting another path.

The default upstream test surface is intentionally preserved. Where the governed direct-block-root profile conflicts with unmodified upstream NullFs behavior, the difference is isolated to this queue and its `blk` feature tests instead of disabling or weakening an upstream security check.

## Update and removal policy

For a new upstream release, create a new immutable baseline, re-derive each patch from its retained evidence, record new identities, and repeat every gate. Never retarget this baseline. Any textual refresh is a new patch identity requiring review even when behavior is intended to be unchanged.

A downstream patch may be removed only when the chosen upstream commit contains equivalent behavior, the mapping is documented path by path, and all reconstruction, contract, mutation, sanitizer, repetition, and coverage gates pass without it. Removing a prerequisite requires proving every dependent patch still applies and retains its security properties.

The compile-only C header contract treats the pre-existing `/dev/input/*` text inside two upstream documentation comments as non-fatal with `-Wno-comment`; all other enabled C warnings are errors. This allowance does not apply to the governed implementation. Rust Clippy denies all warnings except the retained upstream deprecated `GuestMemory::try_access` call exercised by the console corpus. Toolchain versions are pinned separately because formatting detection and retained behavioral measurements require different deterministic compiler versions.

## Known blockers and limitations

- The measured retained console corpus has zero line/function coverage in `port.rs` and `process_tx.rs`; `coverage-baseline.json` preserves this rather than hiding it. Bounded library tests must close or explicitly review this gap before merge.
- AddressSanitizer is supported only on the pinned macOS AArch64 nightly/toolchain route and remains a required governed check there.
- The macOS library gate checks and lints `libkrun` with `blk` and without its default embedded init-blob feature. Compiling the Linux init blob requires the upstream Linux sysroot/cross-toolchain route; this fork supplements, but does not disable, that upstream build gate and retains an installed-build blocker until it passes.
- No installed-product, real-guest, VMM transport, fuzzing, backend-admission, signing, firmware, kernel, or Supervisor evidence is produced here.
- The raw-FD contract is validated with Rust library tests, source-route mutations, and a compile-only C header contract. It is not runtime guest evidence.
- libkrunfw and kernel license/source obligations remain outside this patch line and must be resolved by any eventual distributor.
- Independent human/CODEOWNER review remains required.

Security reports for upstream behavior should follow the private contact documented by upstream. Capsule-specific review must not disclose credentials, proprietary user data, or third-party targets.
