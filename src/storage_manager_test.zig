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
    try h.click("Chapter 4 · 1/1");
    try std.testing.expectEqual(2, h.state().selected.count());
    try h.click("Read");
    try h.runTasks();
    const saved = try engine.loadLibrary(a);
    for (saved.manga[0].chapters, 0..) |chapter, i| try std.testing.expectEqual(i == 0 or i == 4, chapter.read);
    try h.click("Select all");
    try std.testing.expectEqual(8, h.state().selected.count());
    try h.click("Clear selection");
    try std.testing.expectEqual(0, h.state().selected.count());
    try h.click("Previous");
    try h.click("Chapter 0 · 1/1");
    try h.click("Next");
    try h.click("Chapter 4 · 1/1");
    try h.click("Delete");
    try h.answerDialog(1);
    try std.testing.expectEqual(2, h.state().selected.count());
    try h.click("Delete");
    try h.answerDialog(0);
    try h.runTasks();
    const deleted = try engine.loadLibrary(a);
    try std.testing.expectEqual(8, deleted.manga[0].chapters.len);
    for (deleted.manga[0].chapters, 0..) |chapter, i| {
        try std.testing.expectEqual(i != 0 and i != 4, chapter.downloaded());
        try std.testing.expectEqual(i == 0 or i == 4, chapter.read);
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
