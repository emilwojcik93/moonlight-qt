# CONTRACT v1.2 (amendment): Linux AppImage in the moonlight feed

Status: additive amendment to `CONTRACT.md` v1.1 (including 3b). `manifest.schema` stays `1`. Nothing that a v1.1 consumer
reads changes: tag format, ordering key, build numbers, `installer`, `assets[]`, `attestation`, `installer_checks`, signer workflow,
source ref rule and the verification chain of section 4 are exactly as before. Applies to product `moonlight` only
(`emilwojcik93/moonlight-qt`); the vibepollo feed is not affected.

Producer implementation: `ci/appimage_gate.py`, `ci/stage_assets.py`, `ci/manifest_gen.py`, `ci/wrapper/patched-windows-release.yml`
(see `docs/CI.md`). Design: `openspec/changes/linux-client-feed`.

## 1. New release asset

| Asset | Content |
|---|---|
| `Moonlight-<ci_version>-x86_64.AppImage` | upstream's AppImage (type 2, x86-64), built from the patched source by upstream's `build-appimage.yml`, unmodified by the pipeline |

* `<ci_version>` is `manifest.build.version` (`6.2.0-daily.B`, CONTRACT 3b). Name pattern, anchored:
  `^Moonlight-6\.2\.0-daily\.[1-9][0-9]{4}-x86_64\.AppImage$`, and the digits must equal those of `manifest.build.version`.
  Example: tag `v6.2.0-daily.202-vp.1` -> `Moonlight-6.2.0-daily.61616-x86_64.AppImage`.
* The name is also a valid `ASSET_NAME_RE` name (`[A-Za-z0-9][A-Za-z0-9._-]{0,99}`), so the generic rules for asset names apply.
* Only x86-64 exists. A future architecture would use another name (`...-aarch64.AppImage`) and its own key; v1.2 consumers
  must ignore assets and keys they do not know.
* The asset is a release asset of the same immutable release as `MoonlightSetup.exe`: one tag, one build run, one attestation.
  A release is published only when the Windows build, the Linux build and both gates succeeded (immutable releases cannot be
  completed later). Releases published before this amendment have no `linux` key and no AppImage: a Linux consumer must treat
  them as "no Linux asset" (not eligible), never as an error.

## 2. `manifest.json` additions (additive keys)

```json
{
  "linux": {
    "installer": "Moonlight-6.2.0-daily.61616-x86_64.AppImage",
    "sha256": "<64 hex>",
    "size": 76913144
  },
  "linux_checks": {
    "tool": "appimage_gate",
    "ci_version": "6.2.0-daily.61616",
    "image": {"name": "Moonlight-6.2.0-daily.61616-x86_64.AppImage", "sha256": "<64 hex>", "size": 76913144},
    "elf": {"machine": "x86_64", "appimage_type": 2, "squashfs_offset": 944632},
    "squashfs": {"compression": "zstd", "bytes_used": 75968512},
    "embedded": {"desktop_version": "6.2.0-daily.61616", "binary_version": "6.2.0-daily.61616", "binary_machine": "x86_64"},
    "reader": "unsquashfs"
  }
}
```

* `linux` has exactly the three keys shown. `linux_checks` is informational (the gate summary re-validated by the producer);
  consumers may ignore it. Both keys are present together or not at all (`manifest_gen.validate_linux`).
* `assets[]` and `installer` keep describing the Windows installer only; the AppImage is deliberately NOT listed in `assets[]`
  so a v1.1 consumer iterating `assets[]` sees exactly what it saw before. A Linux consumer takes name, hash and size from `linux`.
* `manifest.attestation` stays `["attestation.sigstore.json"]`.
* `SHA256SUMS` gains one line, `<sha256>  Moonlight-<ci_version>-x86_64.AppImage` (same `sha256  name` format; still no line for
  itself or the bundle). The Windows installer line and the `manifest.json` line are unchanged.
* Attestation subjects (one multi-subject SLSA provenance v1 bundle, same signer workflow and source ref as before) are now:
  `MoonlightSetup.exe`, `Moonlight-<ci_version>-x86_64.AppImage`, `SHA256SUMS`, `manifest.json`.
* Windows-only fields are byte-identical to what v1.1 produced for the same inputs (golden test
  `test_windows_only_manifest_is_byte_identical_to_the_pre_amendment_output`).

## 3. Verification steps for a Linux consumer (same chain as the Windows installer, CONTRACT section 4 / 3b)

Fail closed at every step; stop at the first failure and install nothing.

1. Tag regex `^v6\.2\.0-daily\.[1-9][0-9]{0,4}-vp\.[1-9][0-9]{0,2}$`, N in 1..8, ordering key `(U, N)` strictly greater than the
   installed one, not in `policy.yml` `deny:`, owner in the allow-list; the release must carry a `linux` key (else not eligible).
2. Cooling-off from `published_at` per policy.
3. Online (token available): `gh release verify <tag> -R emilwojcik93/moonlight-qt` and `gh release verify-asset <tag> <file>`.
   Offline (no token): require API `immutable == true` on the release plus step 5 with `--bundle`.
4. Download into a private per-run directory: `manifest.json`, `SHA256SUMS`, `attestation.sigstore.json` first, the AppImage last,
   only after the manifest and `SHA256SUMS` attestations passed. URL built from validated repo/tag/name; HTTPS; redirects only to
   the GitHub hosts of the Windows updater's allow-list; byte cap = `linux.size` (and a hard ceiling of 400 MiB); detect truncation.
5. For each of `manifest.json`, `SHA256SUMS`, then the AppImage:
   `gh attestation verify <file> --bundle attestation.sigstore.json --repo emilwojcik93/moonlight-qt
   --signer-workflow emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml
   --source-ref refs/heads/build/v6.2.0-daily.<U>-n<N> --source-digest <manifest.build.source_sha>
   --deny-self-hosted-runners --predicate-type https://slsa.dev/provenance/v1
   --cert-oidc-issuer https://token.actions.githubusercontent.com`.
   `--source-ref` is derived from the tag, never taken from the manifest; `source_sha` is trusted only after the manifest passed.
6. Hashes: the SHA-256 computed from the downloaded file == the `SHA256SUMS` line == `manifest.linux.sha256` == the release API
   `digest`; size == `manifest.linux.size`; name == `Moonlight-<manifest.build.version>-x86_64.AppImage` (regex of section 1).
7. Install from the same verified bytes (no re-download), keep the previous version, never replace a running client. The consumer
   may run `--appimage-extract-and-run` when FUSE is unavailable; running the image is the consumer's smoke test, the producer never
   executes it.

## 4. Producer guarantees (checked before anything is attested)

* The `package` job (no permissions, no secrets) parses the AppImage without executing it and fails the run unless: the name is
  `Moonlight-<ci_version>-x86_64.AppImage`; size is within bounds; ELF 64-bit little-endian x86-64 with `AI\x02` at offset 8;
  the squashfs payload sits where the ELF ends and ends inside the file; the desktop entry `X-AppImage-Version` equals `ci_version`;
  `usr/bin/moonlight` is an x86-64 ELF containing the `VERSION_STR` string `ci_version` and no other `6.2.0-daily.<n>` string.
* `publish` re-hashes the staged AppImage against the sha256 the gate inspected, lists it in `manifest.json` / `SHA256SUMS`,
  attests it, self-verifies it online and offline with the flags of step 5, uploads it, compares the release digests and runs
  `gh release verify-asset` on it.
* Not guaranteed: that the AppImage contents are benign (the build job runs upstream's workflow, which downloads unpinned tools); the
  guarantees are provenance (which workflow, repo, commit), integrity, and the version consistency above.

## 5. Not covered

Flatpak, macOS, ARM Linux, a package repository, delta updates. The consumer implementation (`updater-linux/`) follows this document.
