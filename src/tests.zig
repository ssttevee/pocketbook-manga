const std = @import("std");
const f = @import("fabrum");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;
const fixture: lib.Library = .{ .manga = &.{.{ .id = "story", .title = "Test Story", .chapters = &.{
    .{ .id = "c1", .title = "Chapter 1", .pages = &.{ "story/1/001.png", "story/1/002.png" } },
    .{ .id = "c2", .title = "Chapter 2", .pages = &.{"story/2/001.png"} },
} }} };
test "paths and schema reject unsafe or ambiguous content" {
    try lib.validate(fixture);
    for ([_][]const u8{ "../a", "/a", "a/../b", "a\\b", "a//b", "" }) |path| try std.testing.expect(!lib.safePath(path));
    try std.testing.expectError(error.UnsupportedLibraryVersion, lib.validate(.{ .version = 2 }));
}
test "drawn UI opens chapters, turns pages, resumes and saves completion" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = fixture };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Test Story");
    try h.click("Chapter 1");
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
    try h.click("Next");
    try std.testing.expectEqual(1, model.page);
    try std.testing.expect(model.progress("c1").?.completed);
    try h.click("Back");
    try h.click("Chapter 1");
    try std.testing.expectEqual(1, model.page);
    try h.click("Chapter >");
    try std.testing.expectEqual(1, model.chapter);
    try std.testing.expectEqual(0, model.page);
    try h.click("Aa");
    try h.click("Right to left (manga)");
    try std.testing.expect(!model.prefs.rtl);
}
test "page bounds and stale progress are clamped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = fixture, .prefs = .{ .progress = &.{.{ .id = "c1", .page = 900 }} } };
    try model.dispatch(.{ .open = 0 });
    try model.dispatch(.{ .read = 0 });
    try std.testing.expectEqual(1, model.page);
    try model.dispatch(.{ .turn = 99 });
    try std.testing.expectEqual(1, model.page);
    try model.dispatch(.{ .turn = -99 });
    try std.testing.expectEqual(0, model.page);
    try std.testing.expect(model.progress("c1").?.completed);
}
test {
    _ = @import("smoke.zig");
}
test "local import uses natural order and storage survives an atomic rewrite" {
    const local = @import("local.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "Story/Chapter 10");
    try temp.dir.createDirPath(io, "Story/Chapter 2");
    for ([_][]const u8{ "Story/Chapter 2/10.png", "Story/Chapter 2/2.png", "Story/Chapter 10/1.jpg" }) |path|
        try temp.dir.writeFile(io, .{ .sub_path = path, .data = "fixture" });
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    const indexed = try local.scan(gpa, io, root);
    try std.testing.expectEqualStrings("Chapter 2", indexed.manga[0].chapters[0].title);
    try std.testing.expectEqualStrings("Story/Chapter 2/2.png", indexed.manga[0].chapters[0].pages[0]);
    const path = try std.fs.path.join(gpa, &.{ root, "progress.json" });
    try lib.writeJson(gpa, io, path, lib.Preferences{});
    const expected: lib.Preferences = .{ .rtl = false, .progress = &.{.{ .id = "c1", .page = 7, .completed = true }} };
    try lib.writeJson(gpa, io, path, expected);
    const restored = try lib.readJson(lib.Preferences, gpa, io, path);
    defer restored.deinit();
    try std.testing.expect(!restored.value.rtl);
    try std.testing.expectEqual(7, restored.value.progress[0].page);
    try std.testing.expect(restored.value.progress[0].completed);
}

test "download merge replaces a chapter without losing other titles or chapter order" {
    const companion = @import("catalog.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const old: lib.Library = .{ .manga = &.{
        .{ .id = "a", .title = "Title A", .chapters = &.{
            .{ .id = "c10", .title = "Chapter 10", .pages = &.{"old.png"} },
            .{ .id = "c2", .title = "Chapter 2", .pages = &.{"two.png"} },
        } },
        .{ .id = "b", .title = "Title B" },
    } };
    const merged = try companion.merge(gpa, old, .{ .id = "a", .title = "Title A updated", .chapters = &.{
        .{ .id = "c10", .title = "Chapter 10", .pages = &.{"new.png"} },
        .{ .id = "c3", .title = "Chapter 3", .pages = &.{"three.png"} },
    } });
    try lib.validate(merged);
    try std.testing.expectEqual(2, merged.manga.len);
    try std.testing.expectEqual(3, merged.manga[0].chapters.len);
    try std.testing.expectEqualStrings("Chapter 2", merged.manga[0].chapters[0].title);
    try std.testing.expectEqualStrings("Chapter 3", merged.manga[0].chapters[1].title);
    try std.testing.expectEqualStrings("new.png", merged.manga[0].chapters[2].pages[0]);
    try std.testing.expectEqualStrings("Title B", merged.manga[1].title);
}
test {
    _ = @import("online_test.zig");
}
test "progress owns chapter IDs across replacement of parsed library metadata" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(lib.Library, a, "{\"manga\":[{\"id\":\"story\",\"title\":\"Story\",\"chapters\":[{\"id\":\"c1\",\"title\":\"Chapter 1\",\"pages\":[\"1.png\"]}]}]}", .{ .allocate = .alloc_always });
    var model: lib.Model = .{ .gpa = a, .library = parsed.value };
    defer model.deinit();
    try model.dispatch(.{ .open = 0 });
    try model.dispatch(.{ .read = 0 });
    parsed.deinit();
    model.library = fixture;
    try std.testing.expect(model.progress("c1").?.completed);
}
test "metadata refresh preserves downloaded pages" {
    const catalog = @import("catalog.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const refreshed = try catalog.merge(arena.allocator(), fixture, .{ .id = "story", .title = "Updated story", .chapters = &.{.{ .id = "c1", .title = "New chapter name", .remote = .{ .url = "/c1", .name = "New chapter name" } }} });
    try std.testing.expectEqual(2, refreshed.manga[0].chapters[1].pages.len);
    try std.testing.expectEqualStrings("New chapter name", refreshed.manga[0].chapters[1].title);
}

test "local scanning works without a JVM bundle or a worker" {
    const online = @import("online.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "Offline/Chapter 1");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "Offline/Chapter 1/001.png", .data = "fixture" });
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: online.Engine = .{ .gpa = a, .io = std.testing.io, .root = root };
    defer engine.deinit();
    const job = try online.Job.start(&engine, .scan);
    defer job.deinit();
    job.join();
    try std.testing.expect(job.failure == null);
    try std.testing.expect(job.result.library_changed);
    try std.testing.expectEqual(-1, engine.client.pid);
    const path = try std.fs.path.join(a, &.{ root, "library.json" });
    const saved = try lib.readJson(lib.Library, a, std.testing.io, path);
    defer saved.deinit();
    try std.testing.expectEqualStrings("Offline", saved.value.manga[0].title);
}

test {
    _ = @import("downloads.zig");
    _ = @import("power.zig");
}
