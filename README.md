# PocketManga for PocketBook Verse

A standalone manga app for the **PocketBook Verse PB629**, inspired by Mihon / Tachiyomi. Source extensions, browsing, search, chapter updates, image downloads and reading all run **on the reader**. No desktop companion or server is used.

The app uses fabrum, fabrum-platform-inkview, libinkview and libtachi. Its install bundle includes an **ARM soft-float OpenJDK 17 Zero runtime**, the libtachi host, and public certificate stores. Java and extension work run in a separate, on-demand worker process. The UI never loads the JVM or libtachi. It downloads chapter images with Zig DNS, native TLS and `std.http.Client` over cancellable `std.Io` tasks. Reading downloaded chapters and scanning local manga need only the native InkView app. See [native download design and verification](docs/native-downloads.md).

## Install

Use `dist/pocketmanga-verse.tar.gz`, or copy the contents of `dist/applications/` to the reader's `applications/` folder by USB. Copy the entire bundle, including `applications/pocketmanga/runtime/`; the `.app` launcher alone is insufficient.

**Verse firmware 6.8 or later is supported.** Both executables target Cortex-A7 and ARM EABI soft-float. The UI targets glibc 2.23 and uses the reader's loader, InkView and C++ libraries. Only the tachi worker uses the bundled PocketBook 6.10 glibc 2.39 and GCC runtime libraries. Do not replace the reader's system libraries.

1. Connect the Verse by USB and select **PC link**.
2. Extract the archive onto the reader's storage, merging its `applications/` folder. Preserve any existing `pocketmanga/library.json`, `progress.json`, `extensions/` and `downloads/` when upgrading.
3. On macOS, run `dot_clean /Volumes/READER/applications` to remove `._` files, then eject.
4. Start **pocketmanga** from Applications. Use **pocketmanga-log** if you need diagnostics in `applications/pocketmanga.log`.

After installation, normal use needs only the reader and Wi-Fi. The UI starts the worker through its private loader when online work is requested. For a native chapter, the worker exits as soon as it has resolved the page requests. It otherwise exits after 60 seconds idle; opening a downloaded chapter shuts down an idle worker immediately. Backgrounding or closing the app stops and reaps it. A crashed worker reports an error; the next request can start a fresh one. The launcher retains the executable-stack loader setting needed by some firmware 6.11 releases. A full runtime is included rather than downloaded at first launch.

## Use

- **Browse → Install / update extensions:** filter the repository by name or language, then tap an extension to install or update it. libtachi checks the repository's signing key. Unsupported extension API versions are labelled.
- Tap an installed **source** to view popular titles. Use the reader's system keyboard and **Search**, or switch to **Latest**. **Previous / Next** browse results and source pages.
- Tap a **title** to add it to your library and fetch its chapters. Tap an undownloaded **chapter** to download it and begin reading. Zig downloads plain GET images using the source's resolved requests, headers, cookies and rate limits. Unsupported requests and unknown response-transforming interceptors use the extension's JVM client. Each completed page is saved atomically; retry keeps completed pages, including after cancellation. Failures remain visible with progress and resume instructions.
- **Refresh chapters** updates a title; **Update library** refreshes online titles. Existing page downloads and reading progress survive metadata updates.
- **Source settings** supports text, toggle, list and multi-select preferences, plus extension removal. MangaDex’s **Data saver** toggle selects smaller, more compressed pages. Removing an extension preserves downloaded chapters.
- Cold online requests first show **Loading libtachi worker... (this may take a minute)**, then their actual operation when the JVM is ready. An extension's classes load the first time one of its sources is used, not at worker start, shown as **Loading <name> extension...**, and extension HTTP goes through Zig sockets and TLS rather than the JVM's interpreted TLS. The log records each call's DNS, connect, TLS and header times. Active jobs keep the reader awake and postpone timed power-off; finishing, failure or cancellation releases the guard.
- During background work, **Cancel** interrupts the active `std.Io` operation immediately. An unresponsive JVM worker is terminated after a short cancellation grace period. Tap the chapter again to resume.
- Hardware **Next / Prev** always move in reading order. In RTL mode, tap the page's left half to advance; in LTR mode, tap the right half. At the last page, **Chapter >** opens or downloads the next chapter.
- **Back** returns to chapters, the library, then exits. **Aa** changes direction and full/partial refresh. Progress is saved on each page change.

For local manga, place extracted JPEG/PNG files in `applications/pocketmanga/Title/Chapter/001.jpg`, then tap **Aa → Scan local manga**. Numeric filename runs sort naturally. Scanning merges titles into the existing library and preserves progress; it does not remove entries for deleted folders. No Java startup or network is needed for local scanning or reading.

Data lives in `/mnt/ext1/applications/pocketmanga/`. The app accepts another absolute data folder as its first argument when invoked from a shell. `INKVIEW_LIBRARY` can override the InkView library path.

## Build

Requires Zig **0.17.0**, Python 3.12+, a host JDK 17+ for packaging, and these sibling repositories:

```
pocketbook-manga-app/
zig-layout/
zig-fabrum-platform-inkview/
libinkview/
zig-tachi/
```

libtachi's bundled-CA option (`ca_file`, recorded in `patches/libtachi-ca-file.patch` and part of zig-tachi since `0406ed7`) keeps repository HTTPS verification independent of the device's system certificate paths.

`build.zig.zon` points at `../zig-tachi`. Build its `tachi-host.jar` first with `zig build host` in that repository; the tools read it from `../zig-tachi/zig-out/lib`. On this workspace, use `/Users/steve/Programs/Zig/v0.17.0/zig`; the `zig` on PATH is 0.16.

Extract the checksum-pinned official Verse 6.10.1461 firmware **outside the repo**. Reuse an existing complete extraction if available. `prepare_firmware.py` requires `debugfs` (e2fsprogs) and `unsquashfs`, and reads images without mounting them or using root:

```
python3 tools/prepare_firmware.py 6.10 /tmp/inkview-firmware-6.8-device/verse-6.10.1461.zip --output /tmp/pocketmanga-prepared610
```

The archive URL and SHA256 are in `tools/runtime-packages.json`. Then:

```
ZIG=/Users/steve/Programs/Zig/v0.17.0/zig
"$ZIG" build -Doptimize=small                # native UI, isolated ARM JVM worker and its libzstd JNI decoder
"$ZIG" build test                           # model, persistence, UI and background flows
"$ZIG" build preview -Doptimize=small        # fake-InkView screenshots in preview/*.pgm
python3 tools/preview_png.py                # lossless preview/*.png for review
python3 tools/package_device.py --firmware-root /tmp/pocketmanga-prepared610
```

The packaging script downloads checksum-pinned Debian ARM Java and certificate packages listed in `tools/runtime-packages.json`, dereferences configuration symlinks into a relocatable JRE, and creates Java and PEM stores from public CA certificates. It copies only the allowlisted glibc/GCC runtime files from the firmware extraction and verifies each file's SHA256. InkView and other proprietary firmware libraries are never shipped. Packages are cached in `.runtime-cache/`. It does not install Java on the development computer or change the reader's system libraries. The host jar can be overridden with `--host-jar FILE`. `zig build` compiles the worker's zstd decoder from the libzstd source pinned in zig-tachi's `build.zig.zon`, which needs a JDK's `jni.h` through `JAVA_HOME` or `-Djdk=PATH`; packaging copies it from `zig-out/lib`. Runtime packages retain their upstream licenses under `runtime/licenses/` and `runtime/jre/legal/`.

The former desktop companion has been removed from the source and build. All shipping binaries are ARM device components; the diagnostic and preview targets below are developer tests.

## Verification

```
"$ZIG" build runtime-probe -Doptimize=small
python3 tools/package_device.py --firmware-root /tmp/pocketmanga-prepared610 --test-sysroot
docker build -f tools/Dockerfile.arm-test -t pocketmanga-arm-test:local .
python3 tools/test_arm_runtime.py sources
python3 tools/test_arm_runtime.py repo
python3 tools/test_arm_runtime.py fixture
```

The existing ARM checks invoke the headless worker with the private loader. The optional Debian test sysroot and Docker image emulate the ARM soft-float environment. They are not shipped to the reader. The ARM fixture checks request planning, both rate-limit layouts, null image URL resolution and JVM fallback. The firmware fixture downloads three ~1 MiB PNGs through native TLS and Zig DNS, requiring the extension's header, Referer, cookie-jar cookie and request-interceptor cookie. Its test CA is generated and installed only into temporary container copies, never into dist/. The repository test exercises live HTTPS using the bundle's CA roots.

For the firmware-container checks, also extract the official 6.9.862 archive (the closest available glibc 2.23 stand-in for 6.8), then:

```
python3 tools/prepare_firmware.py 6.9 /tmp/inkview-firmware-6.8-device/verse-6.9.862.zip --output /tmp/pocketmanga-prepared69
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared69 --version 6.9 --log-launcher
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared610 --version 6.10

docker build -f tools/Dockerfile.kernel310-test -t pocketmanga-kernel310-test:local .
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared69 --version 6.9 --deny-new-syscalls --log-launcher
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared610 --version 6.10 --deny-new-syscalls
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared69 --version 6.9 --deny-new-syscalls --parent-exit

python3 tools/audit_runtime.py --rootfs /tmp/pocketmanga-prepared69 --process ui
python3 tools/audit_runtime.py --rootfs /tmp/pocketmanga-prepared69 --process worker
```

Additional strict scenarios exercise cancellation/resume and dynamic redirect fallback:

```
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared69 --version 6.9 --deny-new-syscalls --cancel-resume
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared610 --version 6.10 --deny-new-syscalls --redirect
```

Repeat the ELF audits for the 6.10 root. The containers use the packaged UI, native firmware loader and real InkView library up to symbol resolution, stopping before `InkViewMain`. They exercise the worker's full fixture through the private loader and the actual UI/worker protocol, including progress, crash/retry, version rejection, EOF and idle shutdown. `--parent-exit` deliberately bypasses UI cleanup and checks that its worker exits too. RSS samples include emulator overhead and stop before the hardware event loop.

The extra QEMU build makes post-3.10 **guest** ARM syscalls return `ENOSYS` (including time64 calls), rather than relying on the host's newer kernel. It is a test artifact only. Local firmware Docker images contain proprietary libraries; keep them local. Logs are in `dist/firmware-tests/`. See [the firmware implementation report](docs/firmware-6.8.md) for the syscall audit, process/library ownership and measured results.

UI tests drive the actual fabrum InkView host through its fake framebuffer: source installation, keyboard search, adding a title, downloading and opening a chapter, source preferences, physical keys, tap zones, Back, progress after metadata replacement, and failure handling. Partial image redraws are compared against a full redraw, including padded framebuffer rows.

## Current limits

This is an initial implementation, not feature parity with Mihon. There are no trackers, categories, cover grids, CBZ import, zoom, webtoon scrolling or custom repository UI yet. libtachi supports extensions-lib **1.6**; WebView/Cloudflare challenges, Android bitmap descrambling and some source-specific native compression remain libtachi limitations. JPEG and PNG images are supported; WebP/AVIF chapters fail explicitly.

Zero interprets Java bytecode. Startup and extension loading can be slow on the Verse, especially with large multi-source extensions. The worker starts with a 16 MiB heap, capped at 128 MiB, with 96 MiB for class metadata and 512 KiB Java thread stacks (Serial GC, two active processors); installing many large extensions can exhaust that budget. Network responses have the source client's normal timeouts. Downloads publish their manifest only after every page succeeds; completed pages survive failure or cancellation for retry.

The ARM runtime, JNI bridge, repository connection and UI flows are tested in emulation. **Physical Verse verification is still needed** for real panel refresh, Wi-Fi dialogs, suspend behavior, startup time and peak RAM. Failed startup or corrupt JSON is reported in the log rather than silently resetting user data. Keep the runtime directory and launch through the provided `.app` script.

The Go font and its license are in `src/fonts/`. See zig-tachi's NOTICE for the upstream Mihon and Android compatibility code.

The [device feedback fixes](docs/device-feedback-fixes.md) document extension-compatible zstd decoding (since replaced by source-built libzstd over JNI), download identification and partial-refresh row feedback.
