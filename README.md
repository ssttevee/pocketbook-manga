# PocketManga for PocketBook Verse

Read manga directly on a **PocketBook Verse PB629**. PocketManga lets you browse sources, build a library, download chapters and read offline, with an interface inspired by Mihon / Tachiyomi. Once installed, you only need your reader and Wi-Fi—no desktop companion or server.

**Supported device:** PocketBook Verse PB629 with firmware 6.8 or later. Other PocketBook models have not been verified.

## Download and install

If you have been supplied a prebuilt **`pocketmanga-verse.tar.gz` installation bundle**, use that file. There is no public release download link for this checkout yet. The source-code archive and individual `.app` files are not enough to install the app.

The complete bundle includes everything needed to run PocketManga, including its Java runtime. Developers can produce it using the [build instructions below](#build-from-source).

1. Connect your reader to your computer by USB and choose **PC link** on the reader.
2. Extract the installation bundle. Copy its **`applications`** folder onto the reader's internal storage, merging it with the existing folder. Copy all its contents, including `applications/pocketmanga/runtime/`.
3. Safely eject the reader from your computer, then disconnect the cable.
4. Open **Applications → pocketmanga** on the reader.

**Upgrading?** Keep your existing `applications/pocketmanga/` data. In particular, preserve `tachi.sqlite3`, `progress.json`, `extensions/` and `downloads/`. Replace only the application files supplied in the bundle. Do not copy a database from someone else's installation.

On macOS, if the app does not appear or open correctly, remove Finder's extra metadata files before ejecting:

```sh
dot_clean "/Volumes/READER/applications"
```

Replace `READER` with your reader's volume name. If you need a diagnostic log, launch **pocketmanga-log** instead; it writes `applications/pocketmanga.log`.

## Start reading

1. Turn on Wi-Fi. In **Browse → Extensions**, install an extension for a source you want to use.
2. Open an installed source, then browse or search for a title. **Search all** searches enabled sources together.
3. Open a title, add it to your library and choose a chapter. Reading starts as soon as its starting page has downloaded; the remaining pages download in the background.
4. Use the reader's physical **Next / Prev** buttons, or tap the page, to move through the chapter.

The first online operation can take a while because the extension worker needs to start. The screen shows the current operation. Downloaded chapters can be read without Wi-Fi.

Some sources require browser verification or other features the reader cannot provide. If a download is blocked, PocketManga explains the problem and suggests finding another version or using another source. A temporary network error can be retried without downloading completed pages again.

### Reading controls

Reading starts with the controls hidden. Tap near the **top or bottom edge** to reveal them; tap the page to hide them again. A thin progress bar remains visible along the bottom in paged mode or the right edge in vertical mode.

- **Aa** changes reading direction, viewing mode and screen-refresh settings. Viewing mode is saved per series.
- **Paged** fits the whole page on screen. **Zoom**, beside Aa, lets you enlarge long or wide pages and pan through them. This temporary choice is not saved.
- **Continuous vertical** joins successive images into one scrolling strip, suitable for webtoons and chapters split into small image fragments. Physical Next / Prev move by overlapping screenfuls; dragging moves through image boundaries.
- Tap the **page counter** to jump to a page. The download counter beside it shows how much of a streaming chapter has been saved.
- At the end of a chapter, press Next to reveal the controls and **Chapter >**. This opens or downloads the next chapter.
- **Back** returns to the chapter list, then the library, then exits.

The app keeps the current image visible while preparing a new view and shows a small loading indicator when needed. Repeated navigation while waiting is ignored so a delayed page does not cause several unexpected turns.

### Library, chapters and downloads

The bottom tabs are **Library, Updates, History, Browse** and **More**. More contains the download queue, storage management, settings and other tools.

In the library, use the view button to choose a grid or list, choose a sort order with **Sort**, and reverse it with **Asc / Desc**. Categories and search filter the library. On a series page, tap its title to expand or collapse it, change chapter order, or use **Jump** to find a chapter number.

Chapter rows distinguish unread, partially read, queued and paused downloads. Interrupted downloads show how many pages were saved; tap to resume. Partially read chapters can be marked unread. The download queue shows startup, page listing and transfer progress separately, and can be paused and restarted.

In settings, enable **Hide on-screen Next / Prev buttons** to give lists more space and use the reader's physical buttons instead. Success messages disappear automatically; error banners have a **Dismiss** button.

### Storage and local manga

**More → Manage storage** shows space used on internal storage and the SD card. Choose where new downloads go, manage downloaded series or chapters, and move selected downloads between disks. Pause downloads before moving them. Deleting downloaded files keeps the series and reading progress in your library. Existing downloads keep their original location when you change the destination for new downloads.

For local manga, create folders like this on internal storage:

```text
applications/pocketmanga/local/Title/Chapter/001.jpg
applications/pocketmanga/local/Title/Chapter/002.jpg
```

Then choose **More → Scan local manga**. Scanning and reading local images work offline. Filenames containing numbers are sorted naturally.

### Back up your library

Close PocketManga before copying `applications/pocketmanga/` to your computer. Include any chapter images stored on the SD card if you want to back up those too.

Library information, reading progress, settings and the download queue are stored in **`tachi.sqlite3`**. Display preferences are in `progress.json`; downloaded images remain ordinary files. Older JSON libraries are imported automatically on first use, with the originals retained as migration backups. Keep the database and any active SQLite journal together; never delete a journal while the app is running.

## Compatibility and limitations

PocketManga is still under development and does not provide every Mihon feature. It has been tested on a physical Verse as well as in firmware emulation; behavior on other models and firmware versions may differ.

Supported image families are JPEG, PNG/APNG, WebP, GIF, AVIF, HEIF, JPEG XL and JPEG 2000. Animated images show their first frame. Very large images can exceed the decoder's resource limits. CBZ import is not exposed in this interface.

Source extensions use the extensions-lib 1.6 API. WebView/Cloudflare challenges, Android bitmap descrambling and some source-specific native compression are not supported. Source availability depends on the extension and the source itself.

## Build from source

This section is for developers. You do not need these tools if you already have the installation bundle.

The application and native worker are written in Zig. [libtachi](https://github.com/ssttevee/libtachi) handles manga data and extensions; [fabrum](https://github.com/ssttevee/fabrum), its [InkView platform](https://github.com/ssttevee/fabrum-platform-inkview) and its [renderer](https://github.com/ssttevee/fabrum-renderer-z2d) provide the interface. Zig downloads the pinned dependencies listed in `build.zig.zon`; no sibling checkouts are required.

Install:

- **Zig 0.17.0**. Check `zig version`; another version on your PATH may not work.
- **JDK 17**, with `JAVA_HOME` set to its installation directory. The Java host requests a JDK 17 toolchain.
- **An Android SDK platform**, providing `android.jar`. Set `ANDROID_HOME` to the SDK directory (or use the standard macOS SDK location, `~/Library/Android/sdk`). No Android device is needed.
- **Python 3.12 or later**.
- **Docker**, to build the reader's Java and image runtimes from source.

From the project directory, first build the runtimes:

```sh
python3 tools/build_jre.py
python3 tools/build_images.py
```

The first Java runtime build compiles a cross-toolchain and OpenJDK and can take about an hour. Later builds reuse Docker's cache. Runtime outputs are kept in the ignored `.runtime-cache/` directory.

Then build the extension host, run tests and package the device application:

```sh
zig build host
zig build test
zig build -Doptimize=small
python3 tools/package_device.py
```

`zig build host` installs `zig-out/lib/tachi-host.jar`. The packaging script uses that JAR by default and creates **`dist/pocketmanga-verse.tar.gz`**, ready for installation. The archive contains the application files and runtimes, not your personal library or downloads. `zig build` also supports the default optimization configuration; `-Doptimize=small` is the smaller device build.

If Zig is installed somewhere else, use its full path in each command. Packaging verifies the runtime and certificate downloads against the integrity values recorded in `tools/runtime-packages.json`; it does not change your computer's Java installation or the reader's system libraries.

### Make a change and check it

Start with `src/` for application code and `build.zig` for build targets. Keep related changes together, run **`zig build test`** and **`zig build`**, then check the interface on the device. For changes to decoder behavior, use the production image test bridge described in the development guide.

You can also generate screenshots without a reader:

```sh
zig build preview -Doptimize=small
python3 tools/preview_png.py
```

These write fake-InkView screenshots under `preview/`. They help check layout, but cannot reproduce the reader's panel refresh, Wi-Fi dialogs or suspend behavior.

See [development and verification](docs/development.md) for the architecture, image-cache limits, production codec tests, firmware emulation and packaging details. The [reader wake investigation](docs/reader-wake.md) explains how background work is delivered promptly without periodic completion polling.

## Licenses

The bundle includes license notices for its Java runtime and other components. The Go font and its license are in `src/fonts/`. See libtachi's NOTICE for upstream Mihon and Android compatibility code.
