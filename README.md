# PocketManga

A native manga reader for the **PocketBook Verse (PB629)**, inspired by Mihon / Tachiyomi. Built with Zig 0.17, fabrum, fabrum-platform-inkview, libinkview and libtachi.

This first version has a searchable local library, chapter lists, JPEG/PNG page reading, physical page keys, left/right tap zones, RTL/LTR direction, saved per-chapter progress and completion, and full/partial e-ink refresh settings. A desktop companion installs Mihon extensions, browses sources, searches titles, lists chapters and downloads them for offline reading.

**Extensions run on the computer.** libtachi requires a JVM; this project does not bundle an ARM soft-float JVM for the Verse. The device application is fully offline. On-device source browsing, automatic updates, trackers, categories, cover grids, CBZ archives, zoom and webtoon scrolling are not implemented. No physical reader has been available for hardware verification.

## Build

Keep these local repositories as siblings (no sibling repositories are modified):

```
pocketbook-manga-app/
zig-layout/                    # fabrum
zig-fabrum-platform-inkview/    # InkView platform / event loop
libinkview/                    # SDK documentation and firmware library
zig-tachi/                    # libtachi + JVM host
```

```
zig build -Doptimize=ReleaseSmall          # zig-out/bin/pocketmanga-sync (this computer)
zig build device -Doptimize=ReleaseSmall   # zig-out/bin/pocketmanga.app (Verse)
zig build test                            # model, storage, drawn UI, fake InkView
zig build preview -Doptimize=ReleaseSmall # actual 758×1024 framebuffer screens in preview/*.pgm
zig build sync -- --help
```

The platform loads libinkview dynamically, so no SDK sysroot or vendor compiler is needed. The app adds `LoadJPEG` and `LoadPNGStretch` from libinkview for image decoding; an app-local renderer adds opaque grayscale page content to z2d. fabrum, the platform and both renderer layers share one fabrum module. The device build is ARM Cortex-A7, soft-float EABI, glibc 2.38, and **requires firmware 6.10 or later**. This matches the platform adapter's supported target, rather than the original Verse firmware 6.8.

## Use local manga first

Arrange extracted JPEG / PNG pages in title and chapter directories. Numeric filename runs sort naturally (2 before 10); hidden files and symlinks are ignored.

```
library/
  My Manga/
    Chapter 1/
      001.jpg
      002.jpg
    Chapter 2/
      001.png
```

```
./zig-out/bin/pocketmanga-sync --root ./library import
```

This writes `library/library.json`. Reimport updates matching chapters and preserves other indexed titles and chapters. Removing a folder does not remove its manifest entry: edit `library.json` to remove it, or delete the manifest and reimport to rebuild a purely local library. `progress.json` is separate and is never overwritten by the companion.

## Browse and download through libtachi

Build the JVM host once in zig-tachi (see that project's README):

```
cd ../zig-tachi
zig build host
cd ../pocketbook-manga-app
export TACHI_HOST_JAR="$PWD/../zig-tachi/host/build/libs/tachi-host.jar"
export JAVA_HOME=$(/usr/libexec/java_home)
```

Requires JDK 17+ and the host's build dependencies. Alternatively pass `--host-jar FILE --java-home DIR` to the companion. These are unnecessary for local import.

```
./zig-out/bin/pocketmanga-sync repo
./zig-out/bin/pocketmanga-sync install EXTENSION_PACKAGE
./zig-out/bin/pocketmanga-sync sources
./zig-out/bin/pocketmanga-sync popular SOURCE_ID
./zig-out/bin/pocketmanga-sync search SOURCE_ID "title"
./zig-out/bin/pocketmanga-sync chapters SOURCE_ID 'MANGA_URL'
./zig-out/bin/pocketmanga-sync --root ./library download SOURCE_ID 'MANGA_URL' 'CHAPTER_URL'
```

Take the source ID and URLs from the returned JSON. Extensions and cookies live in `.tachi-data/` by default (`--data-dir` changes it). The default extension repository comes from libtachi. These commands use the source's own image client, including headers and cookies. They do not scrape image URLs with a generic downloader.

Each download uses a new directory, then atomically replaces `library.json` only when every page has downloaded. A failed download leaves the existing library usable; abandoned directories can be removed manually. JPEG and PNG are supported; WebP/AVIF pages fail with `UnsupportedImageFormat`, and Cloudflare / WebView sources have libtachi's existing limitations. Run one companion process per library at a time. Its output is command-line JSON; the companion does not yet provide a desktop GUI.

## Install on the Verse

1. Update to firmware 6.10+ if needed. Connect USB and choose **PC link**.
2. Copy `zig-out/bin/pocketmanga.app` and `zig-out/bin/pocketmanga-log.app` into the reader's `applications/` directory. Preserve executable permissions (`chmod +x` if needed).
3. Copy the **contents** of your `library/` directory into `applications/pocketmanga/`. On subsequent syncs, preserve the reader's `progress.json`; do not mirror-delete it.
4. On macOS, run `dot_clean /Volumes/READER/applications` to remove AppleDouble entries. Eject the reader.
5. Start **pocketmanga-log** from Applications for the first run. It logs to `applications/pocketmanga.log` and sets the executable-stack loader compatibility setting required by some firmware 6.11 releases.

The default on-device data path is `/mnt/ext1/applications/pocketmanga`. A different absolute folder can be passed as the first argument when starting the binary from a shell. `INKVIEW_LIBRARY` can point to a different libinkview library if its soname is not found.

Search by title or author using the system keyboard. Tap a title, then a chapter. **Next/Prev** hardware keys always advance/return in reading order. The left half of the page advances in RTL mode, and the right half advances in LTR mode. The bottom buttons show their actions. At the end of a chapter, **Chapter >** opens the following indexed chapter. **Back** returns to chapters, then the library, then exits. **Aa** opens settings; Back returns to the previous screen. Every page change saves progress with an atomic file replacement; the last page marks the chapter read. Partial refresh mode uses the adapter's periodic cleaning refresh.

## Verification and limits

Tests cover unsafe manifest paths, version validation, page bounds and resume after stale progress, natural import ordering, JSON persistence, system-keyboard search, drawn UI navigation, and the real platform host driven by fake InkView. The host test checks physical page keys, tap direction, refresh hints, Back/exit, download manifest merging, and partial framebuffer output against a full redraw, including image pixels and padded rows. `zig build preview` generates screens from this same host with a synthetic test image (not downloaded manga).

The actual firmware image decoder, power/suspend behavior, loader compatibility and panel ghosting still need testing on the reader. The app currently aborts with a log error for corrupt library/progress JSON instead of silently replacing it. Downloaded paths must remain inside the library; manifests with absolute paths or `..` segments are rejected. Large libraries use paged lists; pages are decoded to at most the panel size and only one page buffer is retained.

`src/fonts/` includes the Go font and its license. Dependencies retain their own licenses; see zig-tachi's NOTICE for its Mihon and Android compatibility code.
