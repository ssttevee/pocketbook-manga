const std = @import("std");
const f = @import("fabrum");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @import("ui.zig");

test "series title expands in flow and collapses back to two lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const title = "The remarkably long adventures of a manga reader travelling through an unfamiliar world with many unexpected companions and mysterious magical powers";
    var model: lib.Model = .{ .gpa = arena.allocator(), .screen = .chapters, .library = .{ .manga = &.{.{ .id = "s", .title = title, .chapters = &.{.{ .id = "c", .title = "Chapter 1" }} }} } };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    defer session.deinit();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    const title_id = h.root().element("series-title");
    const collapsed = h.findElement(title_id).?.bbox;
    try std.testing.expect(collapsed.h <= 42);
    const old_y = h.findText("Chapter 1").?.bbox.y;
    try h.clickElement(title_id);
    try std.testing.expect(model.title_expanded);
    try h.expectText(title);
    try std.testing.expect(h.findElement(title_id).?.bbox.h > collapsed.h);
    try std.testing.expect(h.findText("Chapter 1").?.bbox.y > old_y);
    try h.clickElement(title_id);
    try std.testing.expect(!model.title_expanded);
    try std.testing.expectApproxEqAbs(old_y, h.findText("Chapter 1").?.bbox.y, 0.1);
}

test "jump respects displayed chapter order and fractional chapter numbers" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .screen = .chapters, .chapter_page_rows = 2, .library = .{ .manga = &.{.{ .id = "s", .title = "Story", .chapters = &.{
        .{ .id = "1", .title = "Chapter 1", .number = 1 },
        .{ .id = "2", .title = "Chapter 2", .number = 2 },
        .{ .id = "3", .title = "Chapter 2.5", .number = 2.5 },
        .{ .id = "4", .title = "Special", .number = -1 },
    } }} }, .chapter_rows = &.{ 3, 2, 1, 0 } };
    try model.dispatch(.{ .jump_chapter = "1" });
    try std.testing.expectEqual(2, model.offset);
    try model.dispatch(.{ .jump_chapter = "2.5" });
    try std.testing.expectEqual(0, model.offset);
    try model.dispatch(.{ .jump_chapter = "special" });
    try std.testing.expectEqual(0, model.offset);
    try std.testing.expectError(error.ChapterNotFound, model.dispatch(.{ .jump_chapter = "99" }));
    try std.testing.expectEqual(0, model.offset);
}

test "chapter reading status retains its total after downloaded pages are removed" {
    for ([_]bool{ true, false }) |downloaded| {
        var model: lib.Model = .{ .gpa = std.testing.allocator, .screen = .chapters, .library = .{ .manga = &.{.{ .id = "s", .title = "Story", .chapters = &.{.{ .id = "c", .title = "Chapter 1", .last_read = 1, .last_page_read = 1, .pages = if (downloaded) &.{ "1.png", "2.png", "3.png" } else &.{}, .page_count = 3 }} }} } };
        var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
        defer session.deinit();
        var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
        defer h.deinit();
        try h.frame();
        try h.expectText("Reading 2/3");
    }
}

test "interrupted chapters show saved page counts and jump dialog selects their page" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var chapters: [9]lib.Chapter = undefined;
    for (&chapters, 0..) |*ch, i| ch.* = .{ .id = try std.fmt.allocPrint(arena.allocator(), "c{d}", .{i}), .title = try std.fmt.allocPrint(arena.allocator(), "Chapter {d}", .{i + 1}), .number = @floatFromInt(i + 1) };
    var model: lib.Model = .{ .gpa = arena.allocator(), .screen = .chapters, .library = .{ .manga = &.{.{ .id = "s", .title = "Story", .chapters = &chapters }} } };
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const folder = try std.fmt.allocPrint(a, "downloads/{x}", .{std.hash.Wyhash.hash(0, chapters[8].id)});
    try tmp.dir.createDirPath(std.testing.io, try std.fs.path.join(a, &.{ folder, "1" }));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ folder, "current-plan.json" }), .data = "{\"plan\":\"1\",\"total\":12}" });
    for (1..4) |i| try tmp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/1/{d:0>4}.png", .{ folder, i }), .data = "\x89PNG\r\n\x1a\nfixture" });
    const tachi = @import("tachi");
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    var session: Session = .{ .model = &model, .root = dir, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.refreshRows();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Jump");
    try h.enterText("9");
    try h.expectText("Chapter 9");
    try h.expectText("Unread · Resume 3/12");
    try h.click("Jump");
    try h.enterText("100");
    try h.expectText("Chapter not found in this list");
    try h.expectText("Chapter 9");
}

test "chapter direction toggle persists and stays on the series page" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const tachi = @import("tachi");
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    const library: lib.Library = .{ .manga = &.{.{ .id = "s", .title = "Story", .chapters = &.{
        .{ .id = "2", .title = "Chapter 2", .number = 2, .source_order = 0 },
        .{ .id = "1", .title = "Chapter 1", .number = 1, .source_order = 1 },
    } }} };
    try engine.store.save(a, library);
    var model: lib.Model = .{ .gpa = a, .screen = .chapters, .library = library };
    var session: Session = .{ .model = &model, .root = dir, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.refreshRows();
    const first = model.chapterIndex(0);
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click(if (tachi.views.ChapterFlags.decode(model.library.manga[0].chapter_flags).ascending) "Oldest first" else "Newest first");
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    try std.testing.expect(model.chapterIndex(0) != first);
    const saved = try engine.store.load(a);
    try std.testing.expectEqual(model.library.manga[0].chapter_flags, saved.manga[0].chapter_flags);
}

test "chapter pagination leaves room for a wrapped download failure" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var chapters: [12]lib.Chapter = undefined;
    for (&chapters, 0..) |*ch, i| ch.* = .{ .id = try std.fmt.allocPrint(a, "c{d}", .{i}), .title = try std.fmt.allocPrint(a, "Chapter {d}", .{i + 1}) };
    var model: lib.Model = .{ .gpa = a, .screen = .chapters, .library = .{ .manga = &.{.{ .id = "s", .title = "Story", .source_id = 1, .chapters = &chapters }} } };
    const progress = [_]?@import("tachi").downloads.ResumeProgress{.{ .done = 0, .total = 15 }};
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io, .chapter_downloads = &progress, .download_error = true, .download_blocked = true };
    session.setStatus("This source requires browser verification that PocketManga cannot complete. Find another version or use a different source.");
    defer session.deinit();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.expectText("Unread · Resume 0/15");
    const last = h.findText(chapters[model.pageRows() - 1].title).?;
    const pager = h.findText("Previous").?;
    try std.testing.expect(last.bbox.y + last.bbox.h <= pager.bbox.y);
    try std.testing.expect(pager.bbox.y + pager.bbox.h <= 464);
}

test "returning from reading keeps the current chapter on the measured list page" {
    var chapters: [9]lib.Chapter = undefined;
    for (&chapters) |*chapter| chapter.* = .{ .id = "c", .title = "Chapter", .pages = &.{"1.png"} };
    var model: lib.Model = .{ .gpa = std.testing.allocator, .chapter_page_rows = 4, .library = .{ .manga = &.{.{ .id = "s", .title = "Series", .chapters = &chapters }} } };
    defer model.deinit();
    try model.dispatch(.{ .read = 8 });
    try model.dispatch(.back);
    try std.testing.expectEqual(@as(usize, 8), model.offset);
}

test "confirmation toast expires without moving content and stale dismissals preserve later errors" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = .{ .manga = &.{.{ .id = "s", .title = "Story" }} } };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    defer session.deinit();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    const before = h.findText("Story").?.bbox;
    session.notify("Added to library");
    const old_revision = session.status_revision;
    try h.frame();
    try h.expectText("Added to library");
    try std.testing.expectEqual(before, h.findText("Story").?.bbox);
    try h.advance(.fromMilliseconds(2000));
    try h.expectNoText("Added to library");
    session.setStatus("Cannot save library");
    try h.post(h.root().handler(Root, .dismiss_status), old_revision);
    try h.advance(.fromSeconds(3));
    try h.expectText("Cannot save library");
    try h.click("Dismiss");
    try h.expectNoText("Cannot save library");
    try std.testing.expectEqualStrings("", session.status);
}

test "opening a first page does not label an unread chapter as reading" {
    for ([_]i64{ 0, 1234 }) |last_read| {
        var model: lib.Model = .{ .gpa = std.testing.allocator, .screen = .chapters, .library = .{ .manga = &.{.{ .id = "s", .title = "Story", .chapters = &.{.{ .id = "c", .title = "Chapter 1", .last_read = last_read, .last_page_read = 0, .page_count = 20 }} }} } };
        var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
        defer session.deinit();
        var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
        defer h.deinit();
        try h.frame();
        try h.expectText("Unread · Not downloaded");
        try h.expectNoText("Reading 1/20");
    }
}
