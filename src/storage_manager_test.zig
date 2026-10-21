const std = @import("std");
const f = @import("fabrum");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Manager = @import("storage_manager.zig");
const Harness = f.app.testing.Harness(.{}, Manager);

test "storage manager selections own IDs and toggle without leaking" {
    const a = std.testing.allocator;
    var state: Manager.State = .{};
    defer state.deinit(a);
    const original = try a.dupe(u8, "chapter");
    try state.toggle(a, original);
    a.free(original);
    try std.testing.expect(state.selected.contains("chapter"));
    try state.toggle(a, "chapter");
    try std.testing.expectEqual(0, state.selected.count());
}

test "compact manager selects across pages and marks only selected chapters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var chapters: [8]tachi.library.Chapter = undefined;
    for (&chapters, 0..) |*chapter, i| chapter.* = .{ .id = try std.fmt.allocPrint(a, "chapter-{d}", .{i}), .title = try std.fmt.allocPrint(a, "Chapter {d}", .{i}), .pages = &.{"downloads/test.png"} };
    const library: lib.Library = .{ .manga = &.{.{ .id = "series", .title = "Series", .source_id = 1, .chapters = &chapters }} };
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, library);
    var model: lib.Model = .{ .gpa = a, .library = library };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    defer session.deinit();
    session.browser.engine = &engine;
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 416), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.runTasks();
    try h.click("Chapter 0 · 1/1");
    try h.click("Next");
    try h.click("Chapter 3 · 1/1");
    try std.testing.expectEqual(2, h.state().selected.count());
    try h.click("Read");
    try h.runTasks();
    const saved = try engine.loadLibrary(a);
    for (saved.manga[0].chapters, 0..) |chapter, i| try std.testing.expectEqual(i == 0 or i == 3, chapter.read);
    try h.click("Select all");
    try std.testing.expectEqual(8, h.state().selected.count());
    try h.click("Clear selection");
    try std.testing.expectEqual(0, h.state().selected.count());
    try h.click("Previous");
    try h.click("Chapter 0 · 1/1");
    try h.click("Next");
    try h.click("Chapter 3 · 1/1");
    try h.click("Delete");
    try h.answerDialog(1);
    try std.testing.expectEqual(2, h.state().selected.count());
    try h.click("Delete");
    try h.answerDialog(0);
    try h.runTasks();
    const deleted = try engine.loadLibrary(a);
    try std.testing.expectEqual(8, deleted.manga[0].chapters.len);
    for (deleted.manga[0].chapters, 0..) |chapter, i| {
        try std.testing.expectEqual(i != 0 and i != 3, chapter.downloaded());
        try std.testing.expectEqual(i == 0 or i == 3, chapter.read);
    }
    try std.testing.expectEqual(0, h.state().selected.count());
}

test "bulk deletion preflights missing SD card and preserves all selections and files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "downloads");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "downloads/internal.png", .data = "internal image" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const library: lib.Library = .{ .manga = &.{.{ .id = "series", .title = "Series", .source_id = 1, .chapters = &.{
        .{ .id = "internal", .title = "Internal", .pages = &.{"downloads/internal.png"} },
        .{ .id = "sd", .title = "Card", .pages = &.{"sdcard/downloads/sd.png"} },
    } }} };
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root, .sd_dir = try std.fs.path.join(a, &.{ root, "absent", "pocketmanga" }) });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, library);
    var model: lib.Model = .{ .gpa = a, .library = library };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    defer session.deinit();
    session.browser.engine = &engine;
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 416), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.runTasks();
    try h.click("Select all");
    try h.click("Delete");
    try h.answerDialog(0);
    try h.runTasks();
    try std.testing.expectEqualStrings("Insert the SD card holding these downloads before deleting them.", session.status);
    try std.testing.expectEqual(2, h.state().selected.count());
    const saved = try engine.loadLibrary(a);
    for (saved.manga[0].chapters) |chapter| try std.testing.expect(chapter.downloaded());
    try std.testing.expectEqualStrings("internal image", try tmp.dir.readFileAlloc(std.testing.io, "downloads/internal.png", a, .limited(100)));
}

const move_storage = @import("storage_move.zig");
const png = "\x89PNG\r\n\x1a\npayload";

test "moving complete and partial downloads preserves reading state and resumes on the new disk" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "internal");
    try tmp.dir.createDirPath(io, "card");
    const root = try tmp.dir.realPathFileAlloc(io, "internal", a);
    const card = try tmp.dir.realPathFileAlloc(io, "card", a);
    const plan: [2]tachi.models.ImageRequest = .{
        .{ .page = .{ .index = 0, .url = "https://example.com/1" }, .url = "https://example.com/1.png", .method = "GET", .headers = &.{} },
        .{ .page = .{ .index = 1, .url = "https://example.com/2" }, .url = "https://example.com/2.png", .method = "GET", .headers = &.{} },
    };
    const complete = try tachi.downloads.PageStore.init(a, io, root, "complete", &plan);
    const partial = try tachi.downloads.PageStore.init(a, io, root, "partial", &plan);
    const pages = [_][]const u8{ try complete.put(0, png), try complete.put(1, png) };
    _ = try partial.put(0, png);
    const manifest = try std.fmt.allocPrint(a, "{s}/downloads/{x}/current-plan.json", .{ root, std.hash.Wyhash.hash(0, "partial") });
    try tachi.library.writeJsonAtomic(a, io, manifest, .{ .plan = std.fs.path.basename(partial.folder), .total = 2 });
    var engine: tachi.Engine = .init(a, io, tachi.backend.none, .{ .dir = root, .sd_dir = card });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{ .manga = &.{.{ .id = "series", .title = "Series", .source_id = 1, .chapters = &.{
        .{ .id = "complete", .title = "Complete", .pages = &pages, .read = true, .last_page_read = 1 },
        .{ .id = "partial", .title = "Partial" },
    } }} });
    try std.testing.expectEqual(2, try move_storage.move(&engine, &.{ "complete", "partial" }, true, null));
    var saved = try engine.loadLibrary(a);
    try std.testing.expect(saved.manga[0].chapters[0].read);
    try std.testing.expectEqual(1, saved.manga[0].chapters[0].last_page_read);
    for (saved.manga[0].chapters[0].pages) |page| {
        try std.testing.expect(std.mem.startsWith(u8, page, "sdcard/"));
        try std.testing.expectEqualStrings(png, try std.Io.Dir.cwd().readFileAlloc(io, try engine.pagePath(a, page), a, .limited(100)));
    }
    try std.testing.expect((try engine.downloadTarget(a, "partial")).sd_card);
    try std.testing.expectEqual(1, (try engine.downloadProgress(a, "partial")).?.done);
    try std.testing.expectEqual(2, try move_storage.move(&engine, &.{ "complete", "partial" }, false, null));
    saved = try engine.loadLibrary(a);
    try std.testing.expect(!std.mem.startsWith(u8, saved.manga[0].chapters[0].pages[0], "sdcard/"));
    try std.testing.expect(!(try engine.downloadTarget(a, "partial")).sd_card);
    try std.testing.expectEqual(1, (try engine.downloadProgress(a, "partial")).?.done);
}

test "canceled and conflicting storage moves preserve source and metadata" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "internal");
    try tmp.dir.createDirPath(io, "card");
    const root = try tmp.dir.realPathFileAlloc(io, "internal", a);
    const card = try tmp.dir.realPathFileAlloc(io, "card", a);
    const store = try tachi.downloads.PageStore.init(a, io, root, "chapter", &.{});
    const page = try store.put(0, png);
    var engine: tachi.Engine = .init(a, io, tachi.backend.none, .{ .dir = root, .sd_dir = card });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{ .manga = &.{.{ .id = "series", .title = "Series", .source_id = 1, .chapters = &.{.{ .id = "chapter", .title = "Chapter", .pages = &.{page} }} }} });
    const Cancellation = struct {
        checks: usize = 0,
        fn check(ctx: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.checks += 1;
            // Preflight has seen the plan folder and page; interrupt after the
            // staging tree exists, while its page is being copied.
            if (self.checks == 6) return error.Canceled;
        }
    };
    var cancellation: Cancellation = .{};
    try std.testing.expectError(error.Canceled, move_storage.move(&engine, &.{"chapter"}, true, .{ .context = &cancellation, .check = Cancellation.check }));
    try std.testing.expectEqualStrings(png, try std.Io.Dir.cwd().readFileAlloc(io, try engine.pagePath(a, page), a, .limited(100)));
    const saved = try engine.loadLibrary(a);
    try std.testing.expectEqualStrings(page, saved.manga[0].chapters[0].pages[0]);
    const target = try std.fmt.allocPrint(a, "{s}/downloads/{x}", .{ card, std.hash.Wyhash.hash(0, "chapter") });
    try std.Io.Dir.cwd().createDirPath(io, target);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ target, "unrelated" }), .data = "keep" });
    try std.testing.expectError(error.DestinationHasDownloads, move_storage.move(&engine, &.{"chapter"}, true, null));
    engine.options.sd_dir = null;
    try std.testing.expectError(error.StorageUnavailable, move_storage.move(&engine, &.{"chapter"}, true, null));
    try std.testing.expectEqualStrings(png, try std.Io.Dir.cwd().readFileAlloc(io, try engine.pagePath(a, page), a, .limited(100)));
}
