const std = @import("std");
const f = @import("fabrum");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @import("ui.zig");
var first_ready: std.Io.Event = .unset;
var continue_download: std.Io.Event = .unset;

fn stream(engine: *tachi.Engine, job: *tachi.Job) !void {
    const a = job.arena.allocator();
    const states = try a.alloc(tachi.Job.PageState, 2);
    states[0] = .{ .ready = "downloads/fixture/001.png" };
    states[1] = .loading;
    while (!job.page_lock.tryLock()) std.atomic.spinLoopHint();
    job.page_states = states;
    job.page_lock.unlock();
    job.pages_total.store(2, .release);
    job.pages_done.store(1, .release);
    first_ready.set(engine.io);
    try continue_download.wait(engine.io);
    while (!job.page_lock.tryLock()) std.atomic.spinLoopHint();
    states[1] = .{ .ready = "downloads/fixture/002.png" };
    job.page_lock.unlock();
    job.pages_done.store(2, .release);
    const library = try engine.loadLibrary(a);
    const updated = (try tachi.library.setPages(a, library, "chapter", &.{ "downloads/fixture/001.png", "downloads/fixture/002.png" })).?;
    try engine.store.save(a, updated);
    job.result.library_changed = true;
}

test "reader opens a persistent download before its last page and keeps progress while waiting" {
    first_ready = .unset;
    continue_download = .unset;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = stream;
    try engine.store.save(a, .{ .manga = &.{.{ .id = "series", .title = "Story", .source_id = 1, .chapters = &.{.{ .id = "chapter", .title = "Chapter 1", .remote = .{ .url = "/chapter", .name = "Chapter 1" } }} }} });
    var model: lib.Model = .{ .gpa = a, .screen = .chapters };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.reloadLibrary();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Chapter 1");
    const job = session.browser.busy.?;
    try first_ready.wait(std.testing.io);
    try session.poll();
    try std.testing.expect(!job.done.load(.acquire));
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
    try std.testing.expect(session.browser.busy == null);
    try std.testing.expect(session.read_download == job);
    try std.testing.expectEqualStrings("downloads/fixture/001.png", model.current().?.pages[0]);
    try h.frame();
    try h.clickAt(.init(170, 12));
    try h.expectText("DL 1/2");
    try h.click("Next");
    try std.testing.expectEqual(1, model.page);
    try std.testing.expectEqualStrings("", model.current().?.pages[1]);
    try std.testing.expect(!model.readState(model.current().?).read);
    try h.expectNoText("Cannot open page:");
    // The same persistent transfer cannot be queued a second time from menus.
    try session.edit(.download);
    try session.queueUnread();
    try std.testing.expectEqual(0, (try engine.queue.snapshot(&engine, a)).len);
    continue_download.set(std.testing.io);
    job.join();
    try session.poll();
    try h.frame();
    try std.testing.expect(session.read_download == null);
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
    try std.testing.expectEqual(1, model.page);
    try std.testing.expectEqualStrings("downloads/fixture/002.png", model.current().?.pages[1]);
    try h.expectNoText("DL 1/2");
}

test "waiting for an unsaved page permits returning to a saved page without geometry" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .screen = .reader, .region_reader = true, .page = 1, .library = .{ .manga = &.{.{ .id = "s", .title = "S", .chapters = &.{.{ .id = "c", .title = "C" }} }} }, .online_chapter = "c", .online_pages = &.{ "saved.png", "" } };
    defer model.deinit();
    try model.dispatch(.{ .turn = -1 });
    try std.testing.expectEqual(0, model.page);
    try std.testing.expect(!model.readState(model.current().?).read);
}

test "hardware Back abandons the pending reader opening while the queued download continues" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model: lib.Model = .{ .gpa = a, .screen = .chapters, .library = .{ .manga = &.{.{ .id = "s", .title = "S", .chapters = &.{.{ .id = "c", .title = "C" }} }} } };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io, .queued_read = try a.dupe(u8, "c"), .queued_read_pending = true };
    defer session.deinit();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.advance(.fromMilliseconds(1));
    _ = try h.pressKey(.escape, .{});
    try std.testing.expectEqual(lib.Screen.library, model.screen);
    try std.testing.expect(!session.queued_read_pending);
    try std.testing.expectEqualStrings("c", session.queued_read.?);
}

fn offline() !void {
    return error.NetworkUnavailable;
}

test "a queued partial chapter opens its saved page even before its network transfer can start" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const plan: [2]tachi.models.ImageRequest = .{
        .{ .page = .{ .index = 0, .url = "https://fixture/1" }, .url = "https://fixture/1.png", .method = "GET", .headers = &.{} },
        .{ .page = .{ .index = 1, .url = "https://fixture/2" }, .url = "https://fixture/2.png", .method = "GET", .headers = &.{} },
    };
    const store = try tachi.downloads.PageStore.init(a, io, root, "c", &plan);
    const saved = try store.put(0, "\x89PNG\r\n\x1a\npayload");
    try tachi.library.writeJsonAtomic(a, io, try std.fmt.allocPrint(a, "{s}/downloads/{x}/current-plan.json", .{ root, std.hash.Wyhash.hash(0, "c") }), .{ .plan = std.fs.path.basename(store.folder), .total = 2 });
    var engine: tachi.Engine = .init(a, io, tachi.backend.none, .{ .dir = root });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{ .manga = &.{.{ .id = "s", .title = "S", .source_id = 1, .chapters = &.{.{ .id = "c", .title = "C", .remote = .{ .url = "/c", .name = "C" } }} }} });
    _ = try engine.queue.enqueue(&engine, &.{"c"}, false);
    engine.queue.items.items[0].status = .failed;
    engine.queue.items.items[0].failure = try a.dupe(u8, "NetworkUnavailable");
    var model: lib.Model = .{ .gpa = a, .screen = .chapters };
    var session: Session = .{ .model = &model, .root = root, .io = io };
    session.browser.engine = &engine;
    session.browser.ensure_network = offline;
    defer session.deinit();
    try session.reloadLibrary();
    try session.startChapterReading("c");
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
    try std.testing.expectEqualStrings(saved, model.current().?.pages[0]);
    try std.testing.expectEqualStrings("", model.current().?.pages[1]);
    try std.testing.expect(session.browser.busy == null and session.read_download == null);
    try std.testing.expect(session.reader_download_failed);
    try std.testing.expectEqual(1, session.reader_download_done);
    try std.testing.expectEqual(1, (try engine.queue.snapshot(&engine, a)).len);
    try std.testing.expect(!session.download_error);
}
