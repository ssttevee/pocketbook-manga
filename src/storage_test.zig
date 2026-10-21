const std = @import("std");
const f = @import("fabrum");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @import("ui.zig");
const Harness = f.app.testing.Harness(.{}, Root);

test "storage can be reached from More and fits the reader display" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.queue.deinit(&engine);
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("More");
    const nav = h.findElement(h.root().element("bottom-navigation")).?;
    const last = h.findText("Close PocketManga").?;
    try std.testing.expect(last.bbox.y + last.bbox.h <= nav.bbox.y);
    try h.click("Manage storage");
    try std.testing.expectEqual(lib.Screen.storage, model.screen);
    try h.runTasks();
    try h.expectText("SD card: not inserted or unavailable");
    const clear = h.findText("Clear online reading cache").?;
    try std.testing.expect(clear.bbox.x + clear.bbox.w <= 343);
    try std.testing.expect(clear.bbox.y + clear.bbox.h <= 464);
    try h.click("[ ] SD card");
    try std.testing.expectEqual(.internal, (try engine.loadSettings(a)).downloads.storage);
    try std.testing.expectError(error.StorageUnavailable, session.setDownloadStorage(true));
    try h.click("Back");
    try h.expectText("Manage storage");
}

test "storage inspection counts both volumes and cache clearing preserves downloads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "internal/downloads/chapter");
    try tmp.dir.createDirPath(std.testing.io, "internal/cache/chapters/pages");
    try tmp.dir.createDirPath(std.testing.io, "internal/covers");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "internal/covers/cover.png", .data = "cover" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "internal/data.txt", .data = "data" });
    try tmp.dir.createDirPath(std.testing.io, "card/pocketmanga/downloads/chapter");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "internal/downloads/chapter/1.png", .data = "image" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "internal/cache/chapters/pages/page.png", .data = "cache" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "card/pocketmanga/downloads/chapter/2.png", .data = "second image" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "internal", a);
    const sd = try tmp.dir.realPathFileAlloc(std.testing.io, "card/pocketmanga", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root, .sd_dir = sd });
    defer engine.queue.deinit(&engine);
    var model: lib.Model = .{ .gpa = a, .screen = .storage };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.runTasks();
    const snapshot = h.state().storage_snapshot.?;
    try std.testing.expectEqual(5, snapshot.internal.bytes);
    try std.testing.expectEqual(5, snapshot.internal.cache);
    try std.testing.expectEqual(5, snapshot.internal.covers);
    try std.testing.expect(snapshot.internal.other >= 4);
    try std.testing.expectEqual(12, snapshot.sd_card.bytes);
    try std.testing.expect(snapshot.internal.present and snapshot.sd_card.present);
    try std.testing.expect(snapshot.internal.disk_total.? > 0);
    try std.testing.expect(snapshot.internal.used.? <= snapshot.internal.disk_total.?);
    try std.testing.expect(snapshot.sd_card.disk_total.? > 0);
    const clear = h.findText("Clear online reading cache").?;
    try std.testing.expect(clear.bbox.y + clear.bbox.h <= 464);
    try h.expectText("Manage series");
    try h.click("[ ] SD card");
    var reopened: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root, .sd_dir = sd });
    defer reopened.queue.deinit(&reopened);
    try std.testing.expectEqual(.sd_card, (try reopened.loadSettings(a)).downloads.storage);
    try h.click("Clear online reading cache");
    try h.runTasks();
    try h.expectText("Online reading cache cleared");
    try h.advance(.fromMilliseconds(2000));
    try h.expectNoText("Online reading cache cleared");
    try std.testing.expectEqualStrings("image", try tmp.dir.readFileAlloc(std.testing.io, "internal/downloads/chapter/1.png", a, .limited(100)));
    try std.testing.expectEqualStrings("second image", try tmp.dir.readFileAlloc(std.testing.io, "card/pocketmanga/downloads/chapter/2.png", a, .limited(100)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "internal/cache/chapters/pages/page.png", .{}));
}

test "download management shows compact selectable chapters and returns to storage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.queue.deinit(&engine);
    const library: lib.Library = .{ .manga = &.{
        .{ .id = "saved", .title = "Saved story", .source_id = 1, .chapters = &.{ .{ .id = "c1", .title = "Downloaded chapter", .pages = &.{"downloads/1.png"} }, .{ .id = "c2", .title = "Undownloaded chapter" } } },
        .{ .id = "online", .title = "Online story", .source_id = 1, .chapters = &.{.{ .id = "c3", .title = "Online chapter" }} },
    } };
    try engine.store.save(a, library);
    var model: lib.Model = .{ .gpa = a, .screen = .storage, .library = library };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Manage chapters");
    try h.runTasks();
    try h.expectText("Downloads");
    try h.expectText("[ ] Saved story");
    try std.testing.expect(h.findText("Online story") == null);
    try std.testing.expect(!(try engine.loadSettings(a)).library.downloaded_only);
    try h.expectText("Downloaded chapter · 1/1");
    try std.testing.expect(h.findText("Undownloaded chapter") == null);
    try h.click("[ ] Saved story");
    try h.expectText("1 chapter · 1 selected");
    try h.click("Read");
    try std.testing.expect(session.storage_busy);
    try h.click("Back");
    try std.testing.expectEqual(lib.Screen.library, model.screen);
    try std.testing.expect(session.storage_managing);
    try h.runTasks();
    try std.testing.expect(!session.storage_busy);
    try std.testing.expect((try engine.loadLibrary(a)).manga[0].chapters[0].read);
    try h.click("Back");
    try std.testing.expectEqual(lib.Screen.storage, model.screen);
    try std.testing.expect(!session.storage_managing);
    try session.act(.{ .feed = .library });
    try session.refreshRows();
    try h.frame();
    try h.expectText("Online story");
}

test "series storage management groups chapters and applies bulk reading state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.queue.deinit(&engine);
    const library: lib.Library = .{ .manga = &.{.{ .id = "series", .title = "Saved series", .source_id = 1, .chapters = &.{
        .{ .id = "one", .title = "One", .pages = &.{"downloads/one.png"} },
        .{ .id = "two", .title = "Two", .pages = &.{"downloads/two.png"} },
        .{ .id = "three", .title = "Not downloaded" },
    } }} };
    try engine.store.save(a, library);
    var model: lib.Model = .{ .gpa = a, .screen = .storage, .library = library };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Manage series");
    try h.runTasks();
    try h.expectText("1 series · 0 selected");
    try h.expectText("2 downloaded chapters · 2/2");
    try h.click("Select all");
    try h.click("Read");
    try h.runTasks();
    const saved = try engine.loadLibrary(a);
    try std.testing.expect(saved.manga[0].chapters[0].read);
    try std.testing.expect(saved.manga[0].chapters[1].read);
    try std.testing.expect(!saved.manga[0].chapters[2].read);
}
