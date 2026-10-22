# Building and publishing releases

The [firmware and hardware matrix](compatibility.md) determines the supported profiles. Initially these are ARMv7 soft-float glibc 2.23 (firmware 6.8–6.9) and 2.39 (6.10). A firmware number alone cannot establish ABI compatibility on another model. Adding a profile requires investigating its official firmware, checking CPU/loader/calling convention, then running the app and runtime tests before claiming support. Update the target choices in `build.zig`, `PROFILES` in `tools/release_manifest.py`, the runtime pins, both workflow matrices and the compatibility table together.

## Builder publication and cached runtime builds

The [container guide](containers.md) describes the public JVM builder, its two profiles and the local runtime build cache. Only the compiler/dependency builder is published as a current GHCR input. JVM and image-decoder artifacts are compiled from pinned sources by the Zig build graph, verified against reviewed archive checksums and reused from `.zig-cache/` until their inputs change.

Builder publication and app publication are separate operations. **Actions → Publish JVM builders** publishes candidate builder images; it does not update the reviewed source lock. After changing compiler, sysroot, JVM or decoder inputs, follow the guide's [publication steps](containers.md#publish-images-to-ghcr), run the ARM and firmware checks, then update the builder pins and archive checksums before tagging an app release. Manual candidate builds with `--record-digest` remain available in that guide; they never silently edit the lock or bypass package checks.

For ordinary release builds:

```sh
zig build test
zig build package -Dglibc=2.23 -Doptimize=small
# Save this profile's release files before building the second profile.
zig build package -Dglibc=2.39 -Doptimize=small
```

Each package command builds the app, worker, Java extension host and matching runtimes, then writes the installation tree, archive, checksum and runtime manifest under `zig-out/release/`. The runtime archives and manifest are also installed under `zig-out/runtimes/`. Those installed paths are shared between profile invocations; save the first profile's output before switching profiles. Separate cache entries preserve each profile's runtime builds.

Every runtime manifest records the builder identity, artifact checksums, class-data archive checksum, CPU/ABI and firmware range. Packaging also checks the native build's `build-target.json` to prevent mixing profiles. The published builder executes on Linux ARM64; Intel/AMD hosts need ARM64 execution support. Ordinary builds and tests remain Docker-free.

## Cutting a release

1. Run the normal tests and both optimization builds for **each** supported glibc target, plus firmware/runtime checks from [development](development.md). Keep official root filesystems outside Git. Physical checks remain separate from emulation; do not update a hardware matrix entry without an actual report.
2. Update the compatibility matrix and release notes if the evidence changed. Commit everything being released.
3. Create and push a version tag, such as `v0.1.0-alpha.2`. A hyphenated version is marked as a prerelease.
4. The release workflow uses reviewed builder digests, caches the Zig runtime steps, verifies compiled runtime archives against their reviewed checksums, runs Python/codec/Zig tests, cross-builds default and small optimization modes, and uses the package target for every profile. It persists the Zig cache so unchanged runtime inputs can reuse prior outputs.
5. Only after all profiles pass does it create a draft, upload all bundles, checksums, manifests and build evidence, then publish it. A failure leaves no partially published release. Check the workflow and downloads before announcing it.

Each release has two independently installable bundles:

```text
pocketmanga-armv7-softfp-glibc-2.23.tar.gz
pocketmanga-armv7-softfp-glibc-2.39.tar.gz
```

Their `.sha256` files sit beside them. Users need only the matching bundle. Runtime manifests and build evidence are for maintainers and bug reports. The archives include application files only; no library database, settings or downloaded chapters are shipped.

The release workflow can be retried with **Run workflow** and an existing tag at the selected source commit. It may replace draft assets, but refuses to change a published release. Fix a published release with a new version rather than replacing its files.

## Keeping older firmware covered

Preserve the official firmware archives and extracted roots before upgrading your reader. Keep backups in a permanent directory outside the repository; `/tmp` and Docker build caches can be cleared. Both PB629 6.9.862 and 6.10.1461 can be exercised locally without flashing either one. The fixtures check firmware symbol resolution and worker operations on the firmware's own libc; the old-kernel checks remove newer ARM syscalls. These roots are local test inputs and are never uploaded to GitHub Actions or included in releases.

GitHub builds test against the source-built toolchain sysroots. Those tests catch compiler/runtime failures but do **not** replace the local official-firmware tests, nor actual screen, buttons, sleep/wake and Wi-Fi checks. Preserve the last hardware-verified result for an older firmware when adding a newer result. Community reports can expand the matrix using the [testing template](compatibility.md#help-test-another-reader).
