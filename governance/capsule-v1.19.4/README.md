# Capsule governed libkrun v1.19.4 patch line

This directory governs one narrowly scoped downstream patch queue over the immutable upstream libkrun v1.19.4 commit `728df8125077d0db44265f6e997c72b81b65c015`. The queue was merged as `4ea8d1de861ed1c0636fc800b6da8fb71a086aa5` and is preserved by the locked `capsule/baseline-v1.19.4-r1` ref. The historical `capsule/upstream-v1.19.4` line ended at coverage follow-up merge `cf0333cdba478cc34a8570a65b38412da7fd3ecc` and is also locked. The current accepted/default line is `capsule/upstream-v1.19.4-r3` at `7432eda5a49220976b0167005aa43ee622f9d632`, accepted from reviewed head `445df8823a9aa46f7121db8a24a4deac530989aa`. The current mutable target is `capsule/review-v1.19.4-r4`, created at the exact accepted commit `7432eda5a49220976b0167005aa43ee622f9d632`. Later governed updates use a fresh versioned target branch based on the preceding accepted head.

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

The upstream anchor, retained patch-queue merge, and every accepted governed head are immutable. `capsule/baseline-v1.19.4-r1` must remain at the exact original governed merge and must never be rebased, force-pushed, or advanced. Each update starts a fresh versioned target branch from the preceding accepted head; after acceptance that target is locked and may become the fork default. Patch reconstruction always starts from the upstream anchor and compares the retained queue to the original governed merge, so reviewed follow-up changes cannot rewrite its provenance.

The fork's `main` branch is upstream-oriented integration state, not Capsule product state. A change merged only into `main` is unadopted by Capsule. Applicable fixes must be backported as logical commits through a separate governed pull request; never merge `main` wholesale into a governed line. Every pull request must name and read back its base and head explicitly.

Changes to this line require:

- a draft pull request targeting a fresh versioned branch created from the preceding accepted head;
- maintainer self-review with green required checks, resolved conversations, and exact evidence and settings readback;
- zero GitHub-required approving reviews, no most-recent-push approval, and no required CODEOWNER approval while `@dills122` is the only qualified maintainer; external approval enforcement may be enabled when a second qualified maintainer is available;
- separate human acceptance of DCO responsibility and the repository's required assistance trailer on every commit; automation must not add a human `Signed-off-by` trailer;
- exact patch reconstruction plus all governed checks in `scripts/verify-governed.sh`;
- explicit resolution of the blockers below; and
- no force-push after review begins unless reviewers are told exactly what changed.

A green workflow is necessary but not sufficient for merge. The PR stays draft while any blocker remains.

## CI routing

`.github/workflows/capsule-governed.yml` runs for current/future versioned governed review and accepted targets, manual dispatch, and no other branch family. It has no path filter, so every pull request to a protected governed target emits the stable `Governed admission` context. The governed checks use fixed local fixtures and library/unit processes only; the scripts reject opt-in guest execution.

The governed wrapper is an offline library-only gate and does not bootstrap a Linux sysroot. `scripts/verify-default-init.sh` remains a standalone, fail-closed probe for a pre-provisioned exact sysroot and cross-toolchain. The existing upstream macOS cross-compilation job provisions that environment and runs `make` with the default Linux init blob, without executing a guest; its result is the pull request's build evidence for that route.

The upstream integration workflow is precisely routed away from pull requests whose base is a versioned `capsule/upstream-v1.19.4*`, `capsule/review-v1.19.4-r*`, or `capsule/accepted-v1.19.4-r*` target, because it installs firmware and executes guests. All other pull requests retain upstream integration behavior. The governed replacement performs no guest execution. Governed Clippy uses the retained Rust 1.93.1 toolchain with only the documented deprecated `GuestMemory::try_access` allowance. Rust 1.97.1 formatting must report exactly the one retained P0-2 line-wrap drift recorded in `expected/cargo-fmt-1.97.1.txt`; any additional difference fails CI. The 55-test `blk` corpus runs with one test thread because two exact retained raw-FD tests use a clock-derived temporary name that can collide under parallel execution on macOS. Serial routing preserves every assertion and the exact retained source bytes. This preserves exact retained patch bytes without silently exempting another path.

The default upstream test surface is intentionally preserved. Where the governed direct-block-root profile conflicts with unmodified upstream NullFs behavior, the difference is isolated to this queue and its `blk` feature tests instead of disabling or weakening an upstream security check.

## Update and removal policy

For a new upstream release, create a new immutable baseline, re-derive each patch from its retained evidence, record new identities, and repeat every gate. Never retarget this baseline. Any textual refresh is a new patch identity requiring review even when behavior is intended to be unchanged.

A downstream patch may be removed only when the chosen upstream commit contains equivalent behavior, the mapping is documented path by path, and all reconstruction, contract, mutation, sanitizer, repetition, and coverage gates pass without it. Removing a prerequisite requires proving every dependent patch still applies and retains its security properties.

The compile-only C header contract treats the pre-existing `/dev/input/*` text inside two upstream documentation comments as non-fatal with `-Wno-comment`; all other enabled C warnings are errors. This allowance does not apply to the governed implementation. Rust Clippy denies all warnings except the retained upstream deprecated `GuestMemory::try_access` call exercised by the console corpus. Toolchain versions are pinned separately because formatting detection and retained behavioral measurements require different deterministic compiler versions.

## Known blockers and limitations

- `coverage-baseline.json` preserves the original zero line/function coverage in `port.rs` and `process_tx.rs`. The follow-up bounded library corpus must report exact before/after measurements without rewriting that baseline evidence.
- `coverage-followup.json` records the bounded follow-up measurement and the remaining uncovered functions, lines, and regions for those two files.
- AddressSanitizer is supported only on the pinned macOS AArch64 nightly/toolchain route and remains a required governed check there.
- The macOS library gate checks and lints `libkrun` with `blk` and without its default embedded init-blob feature. The standalone no-network default-init probe remains blocked when its exact pre-provisioned Linux sysroot/cross-toolchain is absent; the pull request's upstream macOS cross-compilation job must independently pass the default-init build route.
- No installed-product, real-guest, VMM transport, fuzzing, backend-admission, signing, firmware, kernel, or Supervisor evidence is produced here.
- The raw-FD contract is validated with Rust library tests, source-route mutations, and a compile-only C header contract. It is not runtime guest evidence.
- libkrunfw and kernel license/source obligations remain outside this patch line and must be resolved by any eventual distributor.
- Zero GitHub approval enforcement does not satisfy or waive later independent product-admission review, DCO acceptance, or final upstream-submission authorization.

Security reports for upstream behavior should follow the private contact documented by upstream. Capsule-specific review must not disclose credentials, proprietary user data, or third-party targets.
