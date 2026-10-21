const std = @import("std");
const f = @import("fabrum");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;
const fixture: lib.Library = .{ .manga = &.{.{ .id = "story", .title = "Test Story", .chapters = &.{
    .{ .id = "c1", .title = "Chapter 1", .pages = &.{ "story/1/001.png", "story/1/002.png" } },
    .{ .id = "c2", .title = "Chapter 2", .pages = &.{"story/2/001.png"} },
} }} };
test "page paths stay inside the library" {
    for ([_][]const u8{ "../a", "/a", "a/../b", "a\\b", "a//b", "" }) |path| try std.testing.expect(!lib.safePath(path));
}
test "drawn UI opens chapters, turns pages, resumes and saves completion" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // libtachi picks the next chapter and records progress.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    var engine: tachi.Engine = .init(std.testing.allocator, std.testing.io, tachi.backend.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    try engine.store.save(arena.allocator(), fixture);
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = fixture };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    session.browser.engine = &engine;
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Test Story");
    try h.click("Chapter 1");
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
    try h.click("Next");
    try std.testing.expectEqual(1, model.page);
    try std.testing.expect(model.readState(fixture.manga[0].chapters[0]).read);
    try h.click("Back");
    try h.click("Chapter 1");
    try std.testing.expectEqual(1, model.page);
    try h.click("Chapter >");
    try std.testing.expectEqual(1, model.chapter);
    try std.testing.expectEqual(0, model.page);
    try h.click("Aa");
    try h.click("Right to left (manga)");
    try std.testing.expect(!model.prefs.rtl);
    // History lists the chapter read last; tapping it opens the reader.
    try h.click("Back");
    try h.click("Back");
    try h.click("Back");
    try std.testing.expectEqual(lib.Screen.library, model.screen);
    try h.click("History");
    try std.testing.expectEqual(lib.Screen.history, model.screen);
    try std.testing.expectEqual(1, session.feed.len);
    try std.testing.expectEqual(1, session.feed[0].pick.chapter);
    try h.click("Test Story");
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
    try std.testing.expectEqual(1, model.chapter);
}
test "chapter and title menus edit the library through libtachi" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(std.testing.allocator, std.testing.io, tachi.backend.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    var stored = fixture;
    stored.categories = &.{.{ .id = 1, .name = "Favorites" }};
    try engine.store.save(a, stored);
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    defer session.deinit();
    session.browser.engine = &engine;
    try session.reloadLibrary();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Test Story");
    try h.click("...");
    try std.testing.expectEqual(lib.Screen.chapter_menu, model.screen);
    try h.click("Bookmark");
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    try std.testing.expect(model.library.manga[0].chapters[0].bookmark);
    try h.click("...");
    try h.click("Mark read");
    try std.testing.expect(model.library.manga[0].chapters[0].read);
    try h.click("Back");
    try h.click("...");
    try std.testing.expectEqual(lib.Screen.title_menu, model.screen);
    try h.click("[ ] Favorites");
    try std.testing.expectEqualSlices(u32, &.{1}, model.library.manga[0].categories);
    try h.click("Remove");
    try std.testing.expectEqual(lib.Screen.library, model.screen);
    try std.testing.expectEqual(0, model.titleCount());
    // Library settings are libtachi's.
    try h.click("More");
    try h.click("Library settings");
    try h.click("[x] Update: skip completed titles");
    try std.testing.expect(!(try engine.loadSettings(a)).update.skip_completed);
    try h.click("Next");
    try h.click("[ ] Reader: skip read chapters");
    try std.testing.expect((try engine.loadSettings(a)).reader.skip_read);
}
test "categories and backups are managed through libtachi" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(std.testing.allocator, std.testing.io, tachi.backend.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, fixture);
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .root = dir, .io = std.testing.io };
    defer session.deinit();
    session.browser.engine = &engine;
    try session.reloadLibrary();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try session.addCategory("Later");
    try session.addCategory("Now");
    try h.click("More");
    try h.click("Categories");
    try h.frame();
    try std.testing.expectEqual(2, model.library.categories.len);
    try h.click("Delete");
    try std.testing.expectEqual(1, model.library.categories.len);
    try std.testing.expectEqualStrings("Now", model.library.categories[0].name);
    try h.click("Back");
    try h.click("Backup and restore");
    try h.click("Create backup");
    session.browser.busy.?.join();
    try session.poll();
    try std.testing.expectEqual(1, session.feed.len);
    try h.frame();
    try h.click(try std.fmt.allocPrint(a, "Restore {s}", .{session.feed[0].title}));
    session.browser.busy.?.join();
    try session.poll();
    try std.testing.expect(std.mem.startsWith(u8, session.status, "Restored"));
}
test "page bounds and stale progress are clamped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const library: lib.Library = .{ .manga = &.{.{ .id = "story", .title = "Story", .chapters = &.{
        .{ .id = "c1", .title = "Chapter 1", .pages = &.{ "1.png", "2.png" }, .last_page_read = 900 },
    } }} };
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = library };
    try model.dispatch(.{ .open = 0 });
    try model.dispatch(.{ .read = 0 });
    try std.testing.expectEqual(1, model.page);
    try model.dispatch(.{ .turn = 99 });
    try std.testing.expectEqual(1, model.page);
    try model.dispatch(.{ .turn = -99 });
    try std.testing.expectEqual(0, model.page);
    try std.testing.expect(model.readState(library.manga[0].chapters[0]).read);
}
test {
    _ = @import("smoke.zig");
    _ = @import("online_test.zig");
    _ = @import("navigation_test.zig");
    _ = @import("cover_test.zig");
    _ = @import("power.zig");
    _ = @import("device_io.zig");
}

fn rememberWithAllocationFailures(a: std.mem.Allocator) !void {
    var model: lib.Model = .{ .gpa = a, .library = fixture };
    defer model.deinit();
    try model.dispatch(.{ .open = 0 });
    try model.dispatch(.{ .read = 0 });
    try model.dispatch(.{ .turn = 1 });
    try model.dispatch(.{ .turn = -1 });
    const c1 = model.readState(fixture.manga[0].chapters[0]);
    try std.testing.expect(c1.read);
    try std.testing.expectEqual(0, c1.page);
    try model.dispatch(.{ .read = 1 });
    try std.testing.expect(model.readState(fixture.manga[0].chapters[1]).read);
}

test "reading changes clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, rememberWithAllocationFailures, .{});
}

test "poll destroys a completed job when library reload fails" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "library.json", .data = "not json" });
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var model: lib.Model = .{ .gpa = a };
    defer model.deinit();
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    const job = try a.create(tachi.Job);
    job.* = .{ .arena = .init(a), .engine = &engine, .request = .scan_local, .result = .{ .library_changed = true } };
    _ = try job.arena.allocator().dupe(u8, "owned job data");
    job.done.store(true, .release);
    session.browser.busy = job;
    try std.testing.expectError(error.SyntaxError, session.poll());
    try std.testing.expect(session.browser.busy == null);
}

test "local scanning works without a JVM bundle or a worker" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "local/Offline/Chapter 1");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "local/Offline/Chapter 1/001.png", .data = "fixture" });
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    const job = try tachi.Job.start(&engine, .scan_local);
    defer job.deinit();
    job.join();
    try std.testing.expect(job.failure == null);
    try std.testing.expect(job.result.library_changed);
    const saved = try engine.loadLibrary(a);
    try std.testing.expectEqualStrings("Offline", saved.manga[0].title);
}

fn replaceBrowserSelection(a: std.mem.Allocator) !void {
    var browser: @import("browser.zig").Browser = .{};
    defer browser.deinit(a);
    const source: @import("tachi").models.SourceInfo = .{
        .id = "42",
        .name = "Old source",
        .lang = "en",
        .supportsLatest = false,
        .isConfigurable = false,
        .className = "Old",
        .extensionPkg = "old.pkg",
    };
    try browser.setSource(a, source);
    var next = source;
    next.id = "99";
    next.name = "New source";
    next.extensionPkg = "new.pkg";
    next.supportsLatest = true;
    browser.setSource(a, next) catch |err| {
        try std.testing.expectEqual(42, browser.source_id);
        try std.testing.expectEqualStrings("Old source", browser.source_name);
        try std.testing.expectEqualStrings("old.pkg", browser.extension_pkg);
        try std.testing.expect(!browser.supports_latest);
        return err;
    };
    try std.testing.expectEqual(99, browser.source_id);
    try std.testing.expectEqualStrings("New source", browser.source_name);
    try std.testing.expectEqualStrings("new.pkg", browser.extension_pkg);
    try std.testing.expect(browser.supports_latest);
    try browser.setPendingChapter(a, "old chapter");
    browser.setPendingChapter(a, "new chapter") catch |err| {
        try std.testing.expectEqualStrings("old chapter", browser.pending_chapter.?);
        return err;
    };
    try std.testing.expectEqualStrings("new chapter", browser.pending_chapter.?);
    // Inputs may alias the owned state being replaced.
    try browser.setPendingChapter(a, browser.pending_chapter.?);
    try std.testing.expectEqualStrings("new chapter", browser.pending_chapter.?);
}

test "browser selections survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, replaceBrowserSelection, .{});
}

fn reloadWithAllocationFailures(a: std.mem.Allocator, root: []const u8) !void {
    var model: lib.Model = .{ .gpa = a };
    defer model.deinit();
    var engine: tachi.Engine = .init(std.testing.allocator, std.testing.io, tachi.backend.none, .{ .dir = root });
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    session.reloadLibrary() catch |err| {
        // Loading may have committed before building the rows ran out of memory.
        if (session.library_arena != null) try std.testing.expectEqualStrings("Test Story", model.library.manga[0].title);
        return err;
    };
    try std.testing.expectEqualStrings("Test Story", model.library.manga[0].title);
}

fn pollSourcesWithAllocationFailures(a: std.mem.Allocator, root: []const u8) !void {
    var model: lib.Model = .{ .gpa = a };
    defer model.deinit();
    var engine: tachi.Engine = .init(std.testing.allocator, std.testing.io, tachi.backend.none, .{ .dir = root });
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    const job = try engine.gpa.create(tachi.Job);
    job.* = .{ .arena = .init(engine.gpa), .engine = &engine, .request = .sources };
    job.result.sources = try job.arena.allocator().dupe(tachi.models.SourceInfo, &.{.{
        .id = "42",
        .name = "Source",
        .lang = "en",
        .supportsLatest = false,
        .isConfigurable = false,
        .className = "Source",
        .extensionPkg = "pkg",
    }});
    job.done.store(true, .release);
    session.browser.busy = job;
    session.poll() catch |err| {
        if (session.browser.sources) |stored| try std.testing.expectEqualStrings("Source", stored.result.sources[0].name);
        // A failed refresh must not publish slices from its discarded arena.
        try std.testing.expectEqual(0, session.browser.source_rows.len);
        return err;
    };
    try std.testing.expectEqual(1, session.browser.source_rows.len);
}

fn pollOnlineWithAllocationFailures(a: std.mem.Allocator, root: []const u8) !void {
    var model: lib.Model = .{ .gpa = a, .library = .{ .manga = &.{.{ .id = "story", .title = "Story", .chapters = &.{.{ .id = "c1", .title = "Chapter" }} }} } };
    defer model.deinit();
    var engine: tachi.Engine = .init(std.testing.allocator, std.testing.io, tachi.backend.none, .{ .dir = root });
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    defer session.deinit();
    const job = try engine.gpa.create(tachi.Job);
    job.* = .{ .arena = .init(engine.gpa), .engine = &engine, .request = .{ .read = .{ .chapter = "c1", .page = 0 } }, .result = .{ .pages = &.{"online/1.png"} } };
    job.done.store(true, .release);
    session.browser.busy = job;
    session.poll() catch |err| {
        if (session.online_arena != null) {
            try std.testing.expectEqualStrings("c1", model.online_chapter.?);
            try std.testing.expectEqualStrings("online/1.png", model.online_pages[0]);
        }
        return err;
    };
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
}

test "session snapshots retain ownership across every allocation failure" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const a = std.testing.allocator;
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    try engine.store.save(a, fixture);
    try std.testing.checkAllAllocationFailures(a, reloadWithAllocationFailures, .{root});
    try std.testing.checkAllAllocationFailures(a, pollSourcesWithAllocationFailures, .{root});
    try std.testing.checkAllAllocationFailures(a, pollOnlineWithAllocationFailures, .{root});
}

fn scanlatorsWithAllocationFailures(a: std.mem.Allocator) !void {
    const library: lib.Library = .{ .manga = &.{.{ .id = "story", .title = "Story", .chapters = &.{
        .{ .id = "1", .title = "One", .scanlator = "First" },
        .{ .id = "2", .title = "Two", .scanlator = "Second" },
        .{ .id = "3", .title = "Three", .scanlator = "First" },
        .{ .id = "4", .title = "Four" },
    } }} };
    var model: lib.Model = .{ .gpa = a, .library = library };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    const groups = try session.scanlators(a);
    defer a.free(groups);
    try std.testing.expectEqual(2, groups.len);
    try std.testing.expectEqualStrings("First", groups[0]);
    try std.testing.expectEqualStrings("Second", groups[1]);
    model.manga = 1;
    const empty = try session.scanlators(a);
    defer a.free(empty);
    try std.testing.expectEqual(0, empty.len);
}

test "scanlator slices work with a general allocator and clean up on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scanlatorsWithAllocationFailures, .{});
}

test "category pagination sorts and displays entries beyond sixty four" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var categories: [70]tachi.library.Category = undefined;
    for (&categories, 0..) |*category, i| {
        const n = categories.len - i;
        category.* = .{ .id = @intCast(n), .order = @intCast(n), .name = try std.fmt.allocPrint(a, "Category {d}", .{n}) };
    }
    var model: lib.Model = .{ .gpa = a, .library = .{ .categories = &categories }, .screen = .categories, .offset = 63 };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.expectText("Category 64");
    try h.expectText("Category 65");
    try h.expectText("Category 70");
    try std.testing.expect(h.findText("Category 63") == null);
    // Sorting the frame copy must not reorder the library itself.
    try std.testing.expectEqual(70, categories[0].id);
    try model.dispatch(.{ .list_page = -1 });
    try h.frame();
    try h.expectText("Category 57");
    try h.expectText("Category 63");
}

fn statusWithAllocationFailures(a: std.mem.Allocator) !void {
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    defer session.deinit();
    session.setStatus("Ready");
    session.formatStatus("Page {d}", .{1}) catch |err| {
        try std.testing.expectEqualStrings("Ready", session.status);
        return err;
    };
    // Formatting can borrow the owned string that it replaces.
    session.formatStatus("{s} failed", .{session.status}) catch |err| {
        try std.testing.expectEqualStrings("Page 1", session.status);
        return err;
    };
    try std.testing.expectEqualStrings("Page 1 failed", session.status);
    session.setStatus("Operation failed");
    try std.testing.expect(session.owned_status == null);
    try session.formatStatus("Retry {d}", .{2});
    try std.testing.expectEqualStrings("Retry 2", session.status);
}

test "status replacement owns formatted messages and survives allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, statusWithAllocationFailures, .{});
}

test "library category tabs reach categories outside the visible window" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var library = fixture;
    library.categories = &.{
        .{ .id = 1, .order = 1, .name = "Favorites" },
        .{ .id = 2, .order = 2, .name = "Reading" },
        .{ .id = 3, .order = 3, .name = "Completed" },
        .{ .id = 4, .order = 4, .name = "Later" },
    };
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = library };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    defer session.deinit();
    try session.refreshRows();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Reading");
    try std.testing.expectEqual(2, model.category);
    try h.click("Completed");
    try std.testing.expectEqual(3, model.category);
    try h.click("Later");
    try std.testing.expectEqual(4, model.category);
    try h.click("Completed");
    try std.testing.expectEqual(3, model.category);
    try h.click("Reading");
    try std.testing.expectEqual(2, model.category);
    try h.click("Favorites");
    try std.testing.expectEqual(1, model.category);
    try h.click("Default");
    try std.testing.expectEqual(0, model.category);
}

test "library cover grid pages two titles and switches to seven row list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var manga: [9]lib.Manga = undefined;
    for (&manga, 0..) |*title, i| title.* = .{
        .id = try std.fmt.allocPrint(a, "title-{d}", .{i}),
        .title = try std.fmt.allocPrint(a, "Story {d}", .{i + 1}),
        .cover = "covers/fixture.png",
    };
    manga[0].title = "A very long manga title that wraps across several lines on a small screen";
    var model: lib.Model = .{ .gpa = a, .library = .{ .manga = &manga, .categories = &.{ .{ .id = 1, .name = "Reading" }, .{ .id = 2, .name = "Later" } } } };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io, .load_cover = @import("smoke.zig").sampleCover };
    defer session.deinit();
    try session.refreshRows();
    session.setStatus("Library updated");
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.expectText("Story 2");
    const pager = h.findText("Previous").?;
    const layout_toggle = h.findText("List").?;
    try std.testing.expect(layout_toggle.bbox.x + layout_toggle.bbox.w <= 343);
    const nav = h.findText("More").?;
    try std.testing.expect(nav.bbox.y + nav.bbox.h <= 464);
    for (manga[0..2]) |title| {
        const caption = h.findText(title.title).?;
        try std.testing.expect(caption.bbox.x >= 0);
        try std.testing.expect(caption.bbox.x + caption.bbox.w <= 343);
        try std.testing.expect(caption.bbox.y + caption.bbox.h <= pager.bbox.y);
    }
    try std.testing.expect(h.findText("Story 3") == null);
    try h.click("Next");
    try std.testing.expectEqual(2, model.offset);
    try h.expectText("Story 4");
    try std.testing.expect(h.findText("Story 5") == null);
    try h.click("Next");
    try h.click("Next");
    try h.click("Next");
    try std.testing.expectEqual(8, model.offset);
    try h.expectText("Story 9");
    try h.click("List");
    try std.testing.expect(!model.prefs.library_grid);
    try std.testing.expectEqual(0, model.offset);
    try h.expectText("Story 7");
    try std.testing.expect(h.findText("Story 8") == null);
    try h.click("Grid");
    try std.testing.expect(model.prefs.library_grid);
    try h.click("...");
    try std.testing.expectEqual(lib.Screen.title_menu, model.screen);
}

test "library pagination clamps both layouts and preserves filters when switching" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var manga: [9]lib.Manga = undefined;
    @memset(&manga, .{ .id = "story", .title = "Story" });
    var model: lib.Model = .{
        .gpa = arena.allocator(),
        .library = .{ .manga = &manga },
        .categories = &.{ "Default", "Reading", "Later" },
        .category = 2,
    };
    try model.dispatch(.{ .search = "Story" });
    try model.dispatch(.{ .list_page = std.math.maxInt(i32) });
    try std.testing.expectEqual(8, model.offset);
    try model.dispatch(.{ .list_page = std.math.minInt(i32) });
    try std.testing.expectEqual(0, model.offset);
    try model.dispatch(.{ .list_page = 1 });
    try std.testing.expectEqual(2, model.offset);
    try model.dispatch(.library_grid);
    try std.testing.expectEqual(0, model.offset);
    try std.testing.expectEqual(2, model.category);
    try std.testing.expectEqualStrings("Story", model.query_text);
    try model.dispatch(.{ .list_page = std.math.maxInt(i32) });
    try std.testing.expectEqual(7, model.offset);
    try model.dispatch(.{ .list_page = std.math.minInt(i32) });
    try std.testing.expectEqual(0, model.offset);
    try model.dispatch(.library_grid);
    try std.testing.expectEqual(2, model.category);
    try std.testing.expectEqualStrings("Story", model.query_text);
}

test "title header and seven chapter rows fit with a real cover and long metadata" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var chapters: [7]lib.Chapter = undefined;
    for (&chapters, 0..) |*chapter, i| chapter.* = .{
        .id = try std.fmt.allocPrint(a, "chapter-{d}", .{i}),
        .title = try std.fmt.allocPrint(a, "Chapter {d}", .{i + 1}),
        .read = i == 0,
        .bookmark = i == 1,
        .scanlator = "A long scanlation group name",
    };
    const manga: lib.Manga = .{
        .id = "story",
        .title = "A very long manga title that wraps over several lines in the detail header",
        .author = "An author with a very long name that should be shortened",
        .cover = "covers/story.png",
        .source_id = 42,
        .chapters = &chapters,
    };
    var model: lib.Model = .{ .gpa = a, .screen = .chapters, .library = .{ .manga = &.{manga} } };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io, .load_cover = @import("smoke.zig").sampleCover };
    defer session.deinit();
    session.setStatus("Library updated");
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    const title = h.findText(manga.title).?;
    try std.testing.expect(title.bbox.x + title.bbox.w <= 343);
    const queue = h.findText("Queue unread").?;
    try std.testing.expect(queue.bbox.x + queue.bbox.w <= 343);
    const last = h.findText("Chapter 7").?;
    const pager = h.findText("Previous").?;
    try std.testing.expect(last.bbox.y + last.bbox.h <= pager.bbox.y);
    try std.testing.expect(pager.bbox.y + pager.bbox.h <= 464);
    const status = h.findText("Library updated").?;
    try std.testing.expect(status.bbox.y + status.bbox.h <= 464);
}
