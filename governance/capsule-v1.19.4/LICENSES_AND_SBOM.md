# License and SBOM inputs

This repository and the retained downstream patches are distributed under the repository's Apache License 2.0 unless a file states otherwise. Keep the top-level `LICENSE` and upstream copyright notices intact.

`sbom-input.cdx.json` is a review input, not a complete release SBOM or attestation. Its immutable inputs are:

- upstream libkrun v1.19.4 commit `728df8125077d0db44265f6e997c72b81b65c015`;
- the five SHA-256 patch identities in `PATCH_QUEUE.json`;
- Cargo dependency resolution in `Cargo.lock`, SHA-256 `9d5dc785636a264794a396ab478821c4ed33acae91650db8d72e8a35733f288c`; and
- the governed source and policy files in this branch.

An eventual distribution must generate a complete SBOM from the exact built sources and binaries, preserve third-party notices, and separately account for libkrunfw, the Linux kernel, toolchains, and native build dependencies. This patch line does not build, modify, package, sign, or admit those components.
