# The worker's Java runtime

The worker runs OpenJDK 17 built from source for the Verse, on the reader's
own C library. It replaces Debian's armel `openjdk-17-jre-headless` (a Zero
interpreter for ARMv5 without an FPU), which needed glibc 2.34 and so ran on
a private copy of PocketBook's 6.10 glibc 2.39 through an explicit loader.
The bundle no longer contains any C library or firmware file.

## What is built

- **OpenJDK 17.0.20.1+1** from the jdk17u `jdk-17.0.20.1-ga` tag, version string
  `17.0.20.1+1-pocketmanga`.
- HotSpot's **ARM32 client VM**: the template interpreter and the C1 JIT,
  with class-data sharing. The `arm-vfp-sflt` ABI profile targets ARMv7 with
  VFP and soft-float calls, the Verse firmware's own ABI (its glibc is
  ARMv7, Thumb-2, VFPv3 and NEON, soft-float calls). Zero has neither a JIT
  nor class-data sharing.
- Linked by jlink to the modules the host and extensions use:
  `java.base`, `java.instrument`, `java.logging`, `java.net.http`, `java.sql`,
  `java.xml`, `jdk.charsets`, `jdk.crypto.ec`, `jdk.localedata` and
  `jdk.unsupported` (Debian's runtime had 69). The module image is
  uncompressed: class loading on the reader is CPU bound.
- Compiled against **glibc 2.23** and Linux 3.10 headers, the 6.8/6.9
  firmware's own. `libjvm.so` and every JDK library need at most
  `GLIBC_2.17` and only libc, libm, libdl, libpthread and librt. GCC's
  libstdc++ and libgcc are linked statically into libjvm.

## How it is built

`tools/build_jre.py` runs `docker build` on `tools/jre/Dockerfile` and checks
the result against the digest pinned in `tools/runtime-packages.json`:

1. **base**: Debian bookworm pinned by image digest, with packages from
   snapshot.debian.org at a fixed date (build tools and the boot JDK).
2. **toolchain**: crosstool-ng 1.29.0 (checksum-pinned) builds GCC 13.4.0
   for `arm-pocketbook-linux-gnueabi` with a glibc 2.23 sysroot from
   `tools/jre/crosstool.config`; crosstool-ng verifies every source tarball.
   About 15 minutes on a 10-core Mac.
3. **deps**: headless OpenJDK still compiles java.desktop, which needs CUPS,
   fontconfig and X11 headers (copied from the pinned Debian packages) and
   an ALSA library to link against (alsa-lib 1.2.16.1, cross-compiled). None
   of it is shipped.
4. **jdk**: fetches the jdk17u commit and runs `tools/jre/build-jdk.sh`,
   which also builds a native JDK of the same version for jlink. About 4
   minutes.
5. **runtime**: jlink, strip, and a tar with sorted names, fixed owners and
   the release date as every timestamp.

The build is reproducible: configure gets `--with-source-date=version` (the
tag's 2026-08-18 release date) and a fixed build user, so a rebuild without
Docker's cache produces the same `pocketmanga-jre.tar`. A different digest
means an input or the build changed.

## Class-data sharing

- **Base archive** (`jre/lib/client/classes.jsa`, 8 MB): JDK classes, dumped
  by the ARM VM itself under qemu against the toolchain's glibc in the
  runtime stage. HotSpot's dump is not byte-for-byte repeatable here, so it
  is exported beside the pinned tar rather than in it; the VM validates it
  against the libjvm and module image it loads with and runs without sharing
  if they differ.
- **Host archive** (`extensions/cache/tachi-host-*.jsa`, about 10 MB): the
  libtachi host's classes, written on the reader. libtachi starts JDK 17 with
  `-XX:+RecordDynamicDumpInfo` when no archive exists, and the worker calls
  `Runtime.saveStartupCache` (jcmd's `VM.cds dynamic_dump`) the first time it
  is idle after a job. The name hashes the libjvm and host jar, so an updated runtime
  or jar gets a fresh archive and stale ones are deleted.

## Measurements

QEMU user emulation on an Apple Silicon Mac, firmware 6.9 root filesystem
with the kernel 3.10 syscall filter. Emulation slows JIT-compiled code more
than interpreted code, so the reader should gain at least as much.

| | Zero (Debian) | Client VM | + host archive |
|---|---|---|---|
| JVM start (fixture) | 3.9 s | 1.3–1.5 s | 0.8 s |
| Image plan (fixture) | 931 ms | 321 ms | |
| MangaFox, 980 chapters: source call | 37.4 s | 3.0–3.7 s | 2.6 s |
| Worker RSS after a download plan | 84 MB | 108 MB | |

## Verification

- `tools/audit_runtime.py --process worker` against the 6.9 and 6.10 root
  filesystems: every versioned symbol in the worker's closure (the worker,
  libjvm and every JRE library) resolves to the firmware's own glibc; no GNU
  runtime library comes from the bundle.
- The firmware suites run the packaged app on both root filesystems; the
  worker probe checks its mappings: the firmware's libc and the bundled
  libjvm, nothing GNU from the app.
