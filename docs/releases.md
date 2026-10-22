# Building and publishing releases

The [firmware and hardware matrix](compatibility.md) determines the supported profiles. Initially these are ARMv7 soft-float glibc 2.23 (firmware 6.8–6.9) and 2.39 (6.10). A firmware number alone cannot establish ABI compatibility on another model. Adding a profile requires investigating its official firmware, checking CPU/loader/calling convention, then running the app and runtime tests before claiming support. Update the target choices in `build.zig`, `PROFILES` in `tools/release_manifest.py`, the runtime pins, both workflow matrices and the compatibility table together.

## Runtime container images

The [container image guide](containers.md) explains each GHCR package, its contents, architecture, usage and build commands. These images are developer build inputs. Readers install the complete bundles from [GitHub Releases](https://github.com/ssttevee/pocketbook-manga/releases).

Runtime publication and app publication are separate operations. **Actions → Publish runtime builders** builds candidate runtime images; it does not update the reviewed source lock. Ordinary app releases fetch the immutable runtime references from `tools/runtime-packages.json`, verify the archive checksums, and package them with the newly built application.

After changing compiler, sysroot, JVM or decoder inputs, follow the guide's [publication steps](containers.md#publish-images-to-ghcr), run the ARM and firmware checks, then update the reviewed checksums and image references before tagging an app release. Every profile's runtime manifest records its builder/runtime image references, artifact checksums, class-data archive checksum, CPU/ABI and firmware range. Packaging also checks the native build's `build-target.json` to prevent mixing profiles.

For local builds, use the builder by its digest from a successful workflow's manifest:

```sh
BUILDER='ghcr.io/ssttevee/pocketmanga-jvm-builder@sha256:REPLACE_WITH_DIGEST'
python3 tools/build_jre.py --glibc 2.39 --builder-image "$BUILDER" --record-digest
python3 tools/build_images.py --glibc 2.39 --toolchain-image "$BUILDER" --record-digest
python3 tools/release_manifest.py --glibc 2.39 \
  --jre .runtime-cache/jre-glibc-2.39 --images .runtime-cache/image-glibc-2.39 \
  --builder "$BUILDER" --output .runtime-cache/runtime-manifest-2.39.json
zig build host
zig build test
zig build -Dglibc=2.39 -Doptimize=small
python3 tools/package_device.py --glibc 2.39 \
  --runtime-manifest .runtime-cache/runtime-manifest-2.39.json
```

`--record-digest` explicitly records newly built outputs for review; it never edits the source lock or bypasses the packaging checksum checks. Without it, local builds must match reviewed values in `tools/runtime-packages.json`. Use an ARM64 Docker builder when consuming the published builders. Building entirely from source also works on other Linux Docker host architectures, but output digests must be reviewed for that host.

## Cutting a release

1. Run the normal tests and both optimization builds for **each** supported glibc target, plus firmware/runtime checks from [development](development.md). Keep official root filesystems outside Git. Physical checks remain separate from emulation; do not update a hardware matrix entry without an actual report.
2. Update the compatibility matrix and release notes if the evidence changed. Commit everything being released.
3. Create and push a version tag, such as `v0.1.0-alpha.2`. A hyphenated version is marked as a prerelease.
4. The release workflow fetches the reviewed public runtime images by digest, verifies their archive checksums, builds the Java host, runs Python/codec/Zig tests, cross-builds default and small optimization modes, and packages the small build for every profile.
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
