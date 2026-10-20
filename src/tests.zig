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
    try h.click("Remove from library");
    try std.testing.expectEqual(lib.Screen.library, model.screen);
    try std.testing.expectEqual(0, model.titleCount());
    // Library settings are libtachi's.
    try h.click("Aa");
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
    try h.click("Aa");
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
    _ = @import("power.zig");
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
