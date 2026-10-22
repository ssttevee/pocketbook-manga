# PocketManga developer container images

The images in GitHub's **Packages** area are build tools and supporting runtime artifacts for developers. Run them on a development computer or CI runner.

To install PocketManga on a reader, download an installation bundle from [GitHub Releases](https://github.com/ssttevee/pocketbook-manga/releases) and follow the [installation instructions](../README.md#download-and-install). The release bundle includes the app and its runtimes; using PocketManga does not require Docker.

## What each image is for

All three packages are public on GitHub Container Registry (GHCR):

| Image | Purpose | Contents and consumer |
| --- | --- | --- |
| [`ghcr.io/ssttevee/pocketmanga-jvm-builder`](https://github.com/users/ssttevee/packages/container/package/pocketmanga-jvm-builder) | Compile native runtimes for the reader | GCC cross compiler, target sysroot, boot JDK and OpenJDK build dependencies. Used by both runtime Dockerfiles. |
| [`ghcr.io/ssttevee/pocketmanga-jvm`](https://github.com/users/ssttevee/packages/container/package/pocketmanga-jvm) | Distribute the compiled Java runtime used by the extension worker | `/artifacts/pocketmanga-jre.tar`, its `.sha256` file and `classes.jsa` (the JVM's class-data-sharing archive). Copied out for packaging. |
| [`ghcr.io/ssttevee/pocketmanga-images`](https://github.com/users/ssttevee/packages/container/package/pocketmanga-images) | Distribute the compiled image-decoding runtime | `/artifacts/pocketmanga-image.tar` and its `.sha256` file. Contains the libvips bridge and required codec libraries, copied out for packaging. Here, “images” means manga image decoding. |

The two artifact images have a small Debian filesystem for extracting files. They contain supporting runtimes rather than the PocketManga application, UI or a ready-to-install bundle. The builder contains compilers and build dependencies; the runtime images contain their outputs.

The build flow is:

```text
JVM builder ── OpenJDK sources ──────── JVM artifact image ──────┐
            └─ libvips/codec sources ─ Decoder artifact image ─┤
                                                             ├─ Installation bundle
Zig app + native worker + Java extension host ─────────────────┘
```

The builder is shared by both runtimes to keep their compiler and C-library target consistent. Zig builds the application separately. The Java extension-host JAR is also built separately with the development tools listed in the [README](../README.md#build-from-source).

## Firmware profiles, tags and architecture

Every package has these profile tags:

| Tag | Target runtime | Firmware on compatible ARMv7 readers |
| --- | --- | --- |
| `glibc-2.23` | ARM32 soft-float, glibc 2.23 | 6.8–6.9 |
| `glibc-2.39` | ARM32 soft-float, glibc 2.39 | 6.10 |

For example, `ghcr.io/ssttevee/pocketmanga-jvm-builder:glibc-2.39` is the builder for the newer profile. Select the same profile for the app, JVM and decoders. Consult the [hardware matrix](compatibility.md) before assuming another reader is compatible.

Published containers run on **Linux ARM64**; the compiler's output runs on the reader's **ARM32 soft-float** userspace. These are different architectures. An Intel/AMD computer can download and extract the artifact images without running them. Executing the published builder requires an ARM64 Docker host or configured ARM64 emulation. Runtime builds also use QEMU inside the build to check ARM32 outputs.

Profile tags are convenient, movable names. Publication also creates tags ending in the source revision. Reviewed builds use immutable registry digests from `tools/runtime-packages.json`, so an updated tag cannot silently change a release's inputs. Commands below read the current references from that file instead of copying specific hashes into documentation.

The containers include a source-built target sysroot for compilation. Installation bundles use the reader's own glibc; proprietary PocketBook firmware is kept outside the containers and releases.

## Use the published runtimes to build PocketManga

This is the usual path for application development: reuse the compiled runtimes and build your app changes. You need Docker, Python 3.12 or newer, and the [application build prerequisites](../README.md#build-from-source). Run commands from the repository root, with Zig 0.17.0 configured as `zig`.

```sh
GLIBC=2.39  # Use 2.23 for firmware 6.8–6.9.
RUNTIMES=".runtime-cache/release-$GLIBC"
python3 tools/fetch_runtimes.py --glibc "$GLIBC" --output "$RUNTIMES"
zig build host
zig build test -Dglibc="$GLIBC"
zig build -Dglibc="$GLIBC" -Doptimize=small
python3 tools/package_device.py --glibc "$GLIBC" \
  --runtime-manifest "$RUNTIMES/runtime-manifest.json" \
  --jre "$RUNTIMES/jre/pocketmanga-jre.tar" \
  --images "$RUNTIMES/images/pocketmanga-image.tar"
```

The fetcher pulls reviewed images by digest, copies `/artifacts/` from stopped containers and checks both runtime archives against the source lock. It removes the temporary containers. Its output includes the archives, JVM class-data archive and a `runtime-manifest.json` recording the exact inputs.

The final installation archive is `dist/pocketmanga-armv7-softfp-glibc-2.39.tar.gz` (or `2.23` for the older profile), with a checksum alongside it. Build outputs and runtime caches remain in ignored directories.

### Inspect an artifact image manually

For example, extract the reviewed JVM image without executing any container code:

```sh
GLIBC=2.39
IMAGE=$(python3 -c 'import json,sys; print(json.load(open("tools/runtime-packages.json"))["runtime_images"][sys.argv[1]]["jre"])' "$GLIBC")
docker pull --platform linux/arm64 "$IMAGE"
container=$(docker create --platform linux/arm64 "$IMAGE")
trap 'docker rm "$container" >/dev/null' EXIT
mkdir -p .runtime-cache/manual-jre
docker cp "$container:/artifacts/." .runtime-cache/manual-jre/
docker rm "$container"
trap - EXIT
```

For decoder artifacts, select `runtime_images[GLIBC]["images"]` instead. Use `fetch_runtimes.py` for normal builds: manual copying alone does not perform its reviewed-checksum verification or generate a packaging manifest. Public pulls need no GHCR login.

## Rebuild runtimes using a published builder

Choose this when changing OpenJDK, codecs or their build configuration. It reuses the expensive compiler/dependency build but compiles the runtime sources again. Use an ARM64 Docker builder when consuming the published builder.

```sh
GLIBC=2.39
BUILDER=$(python3 -c 'import json,sys; print(json.load(open("tools/runtime-packages.json"))["builders"][sys.argv[1]])' "$GLIBC")
DOCKER_DEFAULT_PLATFORM=linux/arm64 python3 tools/build_jre.py --glibc "$GLIBC" --builder-image "$BUILDER"
DOCKER_DEFAULT_PLATFORM=linux/arm64 python3 tools/build_images.py --glibc "$GLIBC" --toolchain-image "$BUILDER"
```

The scripts export files locally, rather than publishing container images:

| Profile | JVM output | Decoder output |
| --- | --- | --- |
| 2.23 | `.runtime-cache/jre/` | `.runtime-cache/image/` |
| 2.39 | `.runtime-cache/jre-glibc-2.39/` | `.runtime-cache/image-glibc-2.39/` |

Each script normally verifies its archive against the reviewed checksum. For deliberately changed inputs, add `--record-digest` to record a candidate `runtime-entry.json` alongside the output. This does not modify the source lock. Test and review the candidate before adopting its checksum; see [release packaging](releases.md) for creating a manifest and packaging a local candidate.

For an interactive compiler check on a compatible Docker host:

```sh
docker run --rm --platform linux/arm64 "$BUILDER" \
  arm-pocketbook-linux-gnueabi-gcc --version
```

## Build the containers locally from source

Docker with BuildKit and network access is required. Compiler and OpenJDK builds are CPU-, memory- and disk-intensive; allow substantial free disk space and roughly an hour for an initial full build. Later builds reuse Docker layers. Docker Desktop or a Linux Docker host supplies the Linux build environment.

The convenience scripts can build everything from source, including a local toolchain:

```sh
python3 tools/build_jre.py --glibc 2.39
python3 tools/build_images.py --glibc 2.39
```

These use the Docker host's build architecture. Outputs from another host architecture must be reviewed rather than assumed to match the published ARM64 build's checksums. `build_jre.py --no-cache` rebuilds its layers, including the toolchain.

To build the same three image types as GHCR, use explicit targets. The build contexts differ: **`tools/jre` for the JVM Dockerfile**, and **the repository root for the decoder Dockerfile**, which copies the application bridge from `src/`.

```sh
GLIBC=2.39
BUILDER="pocketmanga-jvm-builder:glibc-$GLIBC"
docker build --platform linux/arm64 --target deps \
  --build-arg GLIBC_VERSION="$GLIBC" -t "$BUILDER" tools/jre

docker build --platform linux/arm64 --target artifacts \
  --build-arg GLIBC_VERSION="$GLIBC" --build-arg BUILDER_IMAGE="$BUILDER" \
  -t "pocketmanga-jvm:glibc-$GLIBC" tools/jre

docker build --platform linux/arm64 -f tools/image/Dockerfile --target artifacts \
  --build-arg GLIBC_VERSION="$GLIBC" --build-arg TOOLCHAIN_IMAGE="$BUILDER" \
  -t "pocketmanga-images:glibc-$GLIBC" .
```

Repeat with `GLIBC=2.23` for the older profile. These commands create local images; they do not push to GHCR. The default local Docker builder must be able to see the preceding local builder image. A separate remote Buildx builder needs access to an image published in a registry instead.

Dockerfile targets serve different purposes:

| Dockerfile | Target | Result |
| --- | --- | --- |
| `tools/jre/Dockerfile` | `toolchain` | Compiler and sysroot; sufficient as the decoder build's base |
| `tools/jre/Dockerfile` | `deps` | Compiler plus JVM build dependencies; the published builder |
| Either Dockerfile | `artifacts` | Small container with runtime outputs under `/artifacts/`; used for GHCR |
| Either Dockerfile | `export` | Scratch stage for BuildKit `--output type=local,dest=...`; used by the Python build scripts |

For details of the runtime configuration, see [the Java runtime](java-runtime.md) and [image decoders](../tools/image/README.md).

## Publish images to GHCR

Maintainers can run **Actions → Publish runtime builders → Run workflow** in [the repository](https://github.com/ssttevee/pocketbook-manga/actions/workflows/runtimes.yml):

1. Select the source branch or tag containing the intended runtime changes.
2. Enable **publish_builders** to rebuild and publish both compiler/dependency profiles. Disable it to reuse the reviewed builder digests and rebuild only the JVM and decoder artifact images.
3. The workflow builds both profiles on ARM64 runners, runs the JVM and decoder smoke checks, and publishes all selected images. It uses the workflow's `GITHUB_TOKEN` with `packages: write` for authentication.
4. Download the `runtimes-glibc-2.23` and `runtimes-glibc-2.39` workflow artifacts. Each contains the outputs and a manifest of their exact registry references and checksums.
5. Run the [runtime and firmware checks](development.md#firmware-verification), review the outputs, then update `builders`, `runtime_images` and the profile checksums in `tools/runtime-packages.json` as appropriate.

Publishing candidate images does not update that lock or publish an app release. Ordinary app releases fetch reviewed artifacts from it; use the separate [release procedure](releases.md#cutting-a-release) to ship PocketManga.

The existing three packages are public. When introducing another package, check its package visibility and verify an anonymous pull before referencing it in a public build. Container tags can advance independently of app releases; release manifests retain the immutable references used for each bundle.

## Common problems

- **`exec format error`:** executing an ARM64 builder on a host without ARM64 execution support. Use an ARM64 builder or configure emulation. Fetching artifacts with `fetch_runtimes.py` only needs file copying.
- **glibc-profile check fails:** `GLIBC_VERSION` and the selected builder must match. App and packaging profile options must match too.
- **Archive differs from the reviewed checksum:** inspect source, compiler and host-architecture changes. Use `--record-digest` only for a deliberate candidate build, then test and review it.
- **An image builds but has no `/artifacts/`:** check the Dockerfile target. Published artifact images use `--target artifacts`; `export` instead writes outputs through BuildKit's local exporter.
