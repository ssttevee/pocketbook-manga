# PocketManga developer container builds

The public container is a compiler/dependency **builder**, used on a development computer or CI runner. Readers install complete bundles from [GitHub Releases](https://github.com/ssttevee/pocketbook-manga/releases); [installing PocketManga](../README.md#download-and-install) does not require Docker.

## Published builder and firmware profiles

[`ghcr.io/ssttevee/pocketmanga-jvm-builder`](https://github.com/users/ssttevee/packages/container/package/pocketmanga-jvm-builder) contains the GCC cross compiler, target sysroot, boot JDK and OpenJDK build dependencies. Both the JVM and image-decoder Dockerfiles use it, keeping their compiler and C-library target consistent.

| Builder tag | Target runtime | Firmware on compatible ARMv7 readers |
| --- | --- | --- |
| `glibc-2.23` | ARM32 soft-float, glibc 2.23 | 6.8–6.9 |
| `glibc-2.39` | ARM32 soft-float, glibc 2.39 | 6.10 |

The containers execute on **Linux ARM64** and produce **ARM32 soft-float** reader binaries. These are different architectures. Apple Silicon Docker hosts can run the builder directly. An Intel/AMD host needs ARM64 execution support through emulation or a suitable remote Docker host. Runtime smoke checks also use QEMU inside the build to execute ARM32 outputs.

Profile tags are convenient, movable names. Reviewed builds use the immutable builder digests in `tools/runtime-packages.json`, so an updated tag cannot silently change a release's inputs. Public pulls need no GHCR login. The target sysroot is built from public source; installation bundles use the reader's own glibc. Proprietary firmware is never included in the public builder or releases.

Only the builder is a published input for current builds. JVM and decoder archives are generated locally by the Zig build graph; there are no separate runtime-image downloads in this workflow. Previously published runtime artifact images are historical inputs for earlier releases and are not required by current builds.

## Build and cache the runtimes

Install the [development prerequisites](../README.md#build-from-source), start Docker and run from the repository root:

```sh
zig build runtimes -Dglibc=2.39
```

Use `2.23` for firmware 6.8–6.9, or omit the option for that default. The build compiles OpenJDK and the image decoders using the reviewed builder, verifies the resulting runtime archive checksums against the source lock, then installs:

```text
zig-out/runtimes/
  jre/pocketmanga-jre.tar
  jre/classes.jsa
  images/pocketmanga-image.tar
  runtime-manifest.json
```

The manifest records the selected profile, builder and artifact identities for packaging. The class-data archive is separate because its bytes are not reproducible; the JVM validates it when loading it. See [the JVM notes](java-runtime.md#class-data-sharing).

An initial runtime build can be slow: it compiles OpenJDK and the codec libraries even though the compiler is already available. Zig stores successful runtime steps in `.zig-cache/` and reuses them on later builds. CI persists the Zig cache between runs. Docker can also reuse its layers, but the Zig cache determines whether a runtime build command needs to run at all.

Tracked inputs include build scripts, Dockerfiles, source locks, the decoder bridge, glibc profile, immutable builder digest and the `linux/arm64` build platform. A relevant input change invalidates that runtime step. Changing app-only code can reuse both native runtime outputs. Removing the cache makes the next build compile them again; `zig-out/` contains installed results rather than the cache itself.

A lightweight verifier runs even when runtime generation is cached. It checks reviewed archive hashes and the original manifest snapshot, including the separate CDS checksum. If cached files are damaged, clear the Zig cache and rebuild; regenerating a manifest must not approve the damaged files.

Zig 0.17 can rerun a cached command after input timestamps change during cache restoration. The runtime producer recognizes its existing output directory and verifies the receipt written after the original successful build before reusing it. Missing receipts or changed outputs fail verification rather than being accepted as a new build.

The **Cache runtime builds** workflow warms both profiles on the default branch when runtime inputs change. Release tags can restore those caches. Its manual **package** option also runs the full tests and packaging without publishing a release. Cache eviction is safe: the next build regenerates missing outputs with the pinned builder.

For a complete installation bundle:

```sh
zig build test
zig build package -Dglibc=2.39 -Doptimize=small
```

The package target builds the native app and worker, Java extension host and cached runtimes, then writes the installation tree, archive and checksum under `zig-out/release/`. Its profile checks prevent mixing runtimes and app binaries. Ordinary `zig build` and `zig build test` do not invoke Docker.

## Deliberately change runtime sources

When updating OpenJDK, codecs, compiler options or the builder, new output checksums need review before a normal package build accepts them. The manual scripts remain useful for generating those candidates:

```sh
GLIBC=2.39
BUILDER=$(python3 -c 'import json,sys; print(json.load(open("tools/runtime-packages.json"))["builders"][sys.argv[1]])' "$GLIBC")
DOCKER_DEFAULT_PLATFORM=linux/arm64 python3 tools/build_jre.py \
  --glibc "$GLIBC" --builder-image "$BUILDER" --record-digest
DOCKER_DEFAULT_PLATFORM=linux/arm64 python3 tools/build_images.py \
  --glibc "$GLIBC" --toolchain-image "$BUILDER" --record-digest
```

`--record-digest` records a candidate `runtime-entry.json` alongside the output. It never modifies the reviewed source lock or bypasses packaging checks. Without that option, the scripts require the reviewed archive checksums. Default manual outputs are:

| Profile | JVM output | Decoder output |
| --- | --- | --- |
| 2.23 | `.runtime-cache/jre/` | `.runtime-cache/image/` |
| 2.39 | `.runtime-cache/jre-glibc-2.39/` | `.runtime-cache/image-glibc-2.39/` |

Run the [runtime and firmware checks](development.md#firmware-verification), review the candidate, then update the builder pin and archive checksums as appropriate. Normal `zig build runtimes` will then verify and cache the newly reviewed outputs. Building on a different host architecture can change outputs; current reviewed builds use Linux ARM64.

For an entirely local compiler/dependency build:

```sh
GLIBC=2.39
BUILDER="pocketmanga-jvm-builder:glibc-$GLIBC"
docker build --platform linux/arm64 --target deps \
  --build-arg GLIBC_VERSION="$GLIBC" -t "$BUILDER" tools/jre
DOCKER_DEFAULT_PLATFORM=linux/arm64 python3 tools/build_jre.py \
  --glibc "$GLIBC" --builder-image "$BUILDER" --record-digest
DOCKER_DEFAULT_PLATFORM=linux/arm64 python3 tools/build_images.py \
  --glibc "$GLIBC" --toolchain-image "$BUILDER" --record-digest
```

This produces local candidates and does not publish anything. The local Docker builder must be able to see the preceding builder image; a remote Buildx builder instead needs a registry-accessible image. The runtime scripts use the Dockerfiles' `export` targets to write files locally. The JVM build context is `tools/jre`; the decoder context is the repository root because it includes the C bridge from `src/`.

## Publish images to GHCR

Maintainers use **Actions → Publish JVM builders → Run workflow** in [GitHub Actions](https://github.com/ssttevee/pocketbook-manga/actions/workflows/runtimes.yml). Select the intended source branch or tag. The workflow publishes both builder profiles on ARM64 runners using `GITHUB_TOKEN` with `packages: write`; it does not publish JVM or decoder artifact images.

Review the workflow's builder references and build results before updating the reviewed pins in `tools/runtime-packages.json`. Then run cached runtime builds, review any changed archive checksums and perform the ARM and firmware checks before cutting an app release. Publication does not silently update the source lock or publish a PocketManga release. Follow the separate [release procedure](releases.md#cutting-a-release).

When introducing another public builder package, check its visibility and an anonymous pull before referencing it in public builds. Builder tags can advance independently of app releases; manifests retain the immutable input identities used for each bundle.

## Common problems

- **`exec format error`:** the builder executes ARM64 code. Use an ARM64 Docker host or configure ARM64 emulation.
- **glibc-profile check fails:** the app, runtime profile and builder must agree. Use one `-Dglibc` value throughout the Zig package command.
- **Archive differs from the reviewed checksum:** inspect source, compiler and build-platform changes. Generate a deliberate candidate with `--record-digest`, test it and review its checksum before changing the lock.
- **First package build is slow:** the builder avoids compiling the cross-toolchain, but the JVM and decoders still need compilation. Preserve the Zig cache for subsequent builds.
- **Docker is unavailable during an ordinary app check:** `zig build` and `zig build test` are Docker-free. Only runtime/package targets need Docker when their runtime cache is missing or invalidated.

See [the Java runtime](java-runtime.md) and [image decoders](../tools/image/README.md) for component configuration and resource limits.
