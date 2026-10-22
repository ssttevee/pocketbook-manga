# Mihon presentation on PocketBook

The reference is [Mihon's Android UI](https://github.com/mihonapp/mihon/tree/main/app/src/main/java/eu/kanade/presentation), and [official library screenshot](https://mihon.app/home/phone.dark.webp), reviewed on 2026-10-21. Relevant screens are `HomeScreen`, `CommonMangaItem`, `SourcesScreen`, `BaseSourceItem`, `HistoryItem`, `UpdatesUiItem` and `MoreScreen`. PocketManga implements its own Zig widgets and shape-based icons; no Android code, icons or manga artwork was copied.

## Screen mapping

- The persistent root destinations are Library, Updates, History, Browse and More. Reader and detail screens retain Back and reading settings; More groups downloads, categories, statistics, backups, trackers and settings into flat rows.
- Library uses Mihon's comfortable grid pattern: portrait artwork, titles below it, and unread/download counts. Two covers fit per page on the Verse. List mode shows seven compact rows and is saved in display preferences. Search and category tabs work with both modes.
- Title details put artwork next to the title and author. Chapter rows distinguish read, downloaded and bookmarked chapters, with scanlator metadata when available.
- Browse groups Sources and Extensions in adjacent tabs. Source rows have an initial tile, name and language; extension rows retain installation, update and compatibility information.
- Updates and History use cover thumbnails with primary title and secondary chapter information. History keeps a visible Resume affordance on the clickable row.

## Device adaptations

The Verse's 758×1024 panel has a logical viewport of approximately 343×464 points. Pagination, grayscale surfaces and static selected states replace Android scrolling, accent colors, gradients and animation. Hardware page keys and reading tap zones retain their established behavior. Browse results remain in the compact list presentation, which Mihon also supports.

Artwork is separate from the reader page: eight thumbnails, each bounded to 160×240 grayscale pixels, are cached in memory. Local, custom and cached remote covers work offline. Missing remote artwork is fetched sequentially while the worker is already ready; an optional cover does not start a JVM or open a Wi-Fi dialog. Foreground work and reader entry cancel and join optional artwork. Failed or unsupported images keep a placeholder and log the reason. Changed pixels at the same path receive a different damage fingerprint.

## Verification

UI regressions use the real layout at 343×464 points and decoded image content, including long titles, category tabs, status text, seven-row lists and partial final pages. They check that content, pagination and bottom navigation remain on-screen. Cover tests exercise memory ownership, allocation failures, cache pinning, failed loads, readiness gating and cancellation.

Run the existing preview workflow to inspect actual fake-InkView framebuffer output:

```sh
Z=/Users/steve/Programs/Zig/v0.17.0/zig
"$Z" build test
"$Z" build preview
python3 tools/preview_png.py
```

`preview/` is ignored. Fixture covers are deliberately synthetic grayscale artwork; device artwork uses real local or source covers. Physical-panel refresh and touch feel still need a check on a Verse.
