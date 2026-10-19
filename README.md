# PocketManga for PocketBook Verse

A standalone manga app for the **PocketBook Verse PB629**, inspired by Mihon / Tachiyomi. Source extensions, browsing, search, chapter updates, image downloads and reading all run **on the reader**. No desktop companion or server is used.

The app uses fabrum, fabrum-platform-inkview, libinkview and libtachi. Its install bundle includes an **ARM soft-float OpenJDK 17 Zero runtime**, the libtachi host, and public certificate stores. Java and extension work run on a background thread; the InkView UI remains responsive.

## Install

Use `dist/pocketmanga-verse.tar.gz`, or copy the contents of `dist/applications/` to the reader's `applications/` folder by USB. Copy the entire bundle, including `applications/pocketmanga/runtime/`; the `.app` launcher alone is insufficient.

**Firmware 6.10 or later is required.** The app targets Cortex-A7, ARM EABI soft-float and the newer firmware's glibc. The bundled runtime deliberately uses the firmware's C++ library; replacing it with an older Debian C++ library would break libinkview.

1. Connect the Verse by USB and select **PC link**.
2. Extract the archive onto the reader's storage, merging its `applications/` folder. Preserve any existing `pocketmanga/library.json`, `progress.json`, `extensions/` and `downloads/` when upgrading.
3. On macOS, run `dot_clean /Volumes/READER/applications` to remove `._` files, then eject.
4. Start **pocketmanga** from Applications. Use **pocketmanga-log** if you need diagnostics in `applications/pocketmanga.log`.

After installation, normal use needs only the reader and Wi-Fi. The launcher sets Java's library paths and the executable-stack loader setting needed by some firmware 6.11 releases. A full runtime is included rather than downloaded at first launch.

## Use

- **Browse → Install / update extensions:** filter the repository by name or language, then tap an extension to install or update it. libtachi checks the repository's signing key. Unsupported extension API versions are labelled.
- Tap an installed **source** to view popular titles. Use the reader's system keyboard and **Search**, or switch to **Latest**. **Previous / Next** browse results and source pages.
- Tap a **title** to add it to your library and fetch its chapters. Tap an undownloaded **chapter** to download it and begin reading. The download uses the extension's own HTTP client, headers and cookies.
- **Refresh chapters** updates a title; **Update library** refreshes online titles. Existing page downloads and reading progress survive metadata updates.
- **Source settings** supports text, toggle, list and multi-select preferences, plus extension removal. Removing an extension preserves downloaded chapters.
- During background work, **Cancel** stops before the next stage or page; an HTTP request already in progress may need to finish first.
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

libtachi needs the small bundled-CA API addition recorded in `patches/libtachi-ca-file.patch`. It has already been applied to this workspace's `zig-tachi` checkout. For another checkout without it, apply it in zig-tachi with `git apply ../pocketbook-manga-app/patches/libtachi-ca-file.patch`. This keeps repository HTTPS verification independent of the device's system certificate paths.

Build `tachi-host.jar` in zig-tachi (`zig build host` there, following its build prerequisites), then:

```
zig build -Doptimize=ReleaseSmall           # ARM device binary
zig build test                             # model, persistence, UI and background flows
zig build preview -Doptimize=ReleaseSmall   # actual fake-InkView screenshots in preview/*.pgm
python3 tools/package_device.py            # complete dist/applications and .tar.gz
```

The packaging script downloads checksum-pinned Debian ARM packages listed in `tools/runtime-packages.json`, dereferences Debian's configuration symlinks into a relocatable JRE, and creates Java and PEM stores from public CA certificates. Packages are cached in `.runtime-cache/`. It does not install Java on the development computer or change the reader's system libraries. The host jar can be overridden with `--host-jar FILE`. Runtime packages retain their upstream licenses under `runtime/licenses/` and `runtime/jre/legal/`.

The former desktop companion has been removed from the source and build. All shipping binaries are ARM device components; the diagnostic and preview targets below are developer tests.

## Verification

```
zig build runtime-probe -Doptimize=ReleaseSmall
python3 tools/package_device.py --test-sysroot
docker build -f tools/Dockerfile.arm-test -t pocketmanga-arm-test:local .
python3 tools/test_arm_runtime.py sources
python3 tools/test_arm_runtime.py repo
python3 tools/test_arm_runtime.py fixture
```

The optional test sysroot and Docker image emulate the ARM soft-float environment. They are not shipped to the reader. The synthetic fixture uses a local HTTP server that rejects image requests without the extension's header, exercising real ARM JNI loading, extension installation, search, manga details, chapters and image downloads without a manga website. The repository test exercises live HTTPS using the bundle's CA roots.

UI tests drive the actual fabrum InkView host through its fake framebuffer: source installation, keyboard search, adding a title, downloading and opening a chapter, source preferences, physical keys, tap zones, Back, progress after metadata replacement, and failure handling. Partial image redraws are compared against a full redraw, including padded framebuffer rows.

## Current limits

This is an initial implementation, not feature parity with Mihon. There are no trackers, categories, cover grids, CBZ import, zoom, webtoon scrolling or custom repository UI yet. libtachi supports extensions-lib **1.6**; WebView/Cloudflare challenges, Android bitmap descrambling and some source-specific native compression remain libtachi limitations. JPEG and PNG images are supported; WebP/AVIF chapters fail explicitly.

Zero interprets Java bytecode. Startup and extension loading can be slow on the Verse, especially with large multi-source extensions. The heap is capped at 128 MiB with 96 MiB for class metadata; installing many large extensions can exhaust that budget. Network responses have the source client's normal timeouts. Downloads publish their manifest only after every page succeeds; cancelled or failed chapter folders are removed.

The ARM runtime, JNI bridge, repository connection and UI flows are tested in emulation. **Physical Verse verification is still needed** for real panel refresh, Wi-Fi dialogs, suspend behavior, startup time and peak RAM. Failed startup or corrupt JSON is reported in the log rather than silently resetting user data. Keep the runtime directory and launch through the provided `.app` script.

The Go font and its license are in `src/fonts/`. See zig-tachi's NOTICE for the upstream Mihon and Android compatibility code.
