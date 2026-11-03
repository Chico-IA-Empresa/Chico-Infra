# Synthetic fixture image maintenance review

The current official PostgreSQL16 Bookworm ARM64 candidate has four CRITICAL findings. The independent PostgreSQL16 Alpine candidate retains one in the Go standard library compiled into gosu. The current Caddy Alpine candidate has one in brotli-libs. None is approved for host pull. Preserve original raw reports; no VEX, ignore list, severity override or package deletion is introduced.

This manual main-only workflow requires infra-apply-dev approval, repeats governance after waiting and uses a disposable native ARM64 runner. It has no id-token permission, AWS credential action, ECR publication, state/backend/tfvars/Secrets Manager access, database data, SSM execution or host installation. Artifacts contain package inventories, image metadata and synthetic tool versions only. A failed scan cannot claim completion.

PostgreSQL16 Alpine is considered only for the synthetic fixture. It does not approve a distribution/locale/extension choice for the real restored database. Rebuild gosu1.20 from commit29b939aa5bd4dc588af765b8248f6e39150d2565 using official Go1.27.3 ARM64 (both archives SHA pinned), preserving source/module checksums and replacing only its binary. The prebuilt gosu1.20 release still uses Go1.24.6 and is not a remediation. A prior Windows filesystem scan detected no language files; that result is not a clean scan. The new complete image scan requires gosu stdlibv1.27.3 inventory explicitly.

Caddy upgrades only brotli-libs to1.2.1-r0 using the signed Alpine repository and verifies the installed version. [Alpine package provenance](https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/brotli-libs). Sources: [gosu1.20 release](https://github.com/tianon/gosu/releases/tag/1.20), [Go downloads](https://go.dev/dl/), [Trivy0.76.1 release](https://github.com/aquasecurity/trivy/releases/tag/v0.76.1).

Critical or unknown/incomplete inventories block. Noncritical findings remain listed for review. Benign postgres --version, gosu user drop and caddy version probes run only after known scans pass. This is ordinary package maintenance; it runs no vulnerability PoC, corpus, fuzzing or active exploit test.

The workflow records only image/stage identifiers and exit status for a failed build or probe; raw build logs remain temporary on the runner. The exact Brotli version is checked from the complete scanner package inventory rather than human-readable apk output. A partial run preserves its package evidence and cannot produce the completion summary.

Main/source changes require new proof JSON/hash for later protected operations. Publishing/promoting final images, their final digests, installing fixture, secrets/runtime configuration, persistent data and real restore each retain their own reviews and gates. Original checkouts and uncommitted work remain untouched.
