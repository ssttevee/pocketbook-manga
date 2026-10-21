const std = @import("std");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const smoke = @import("smoke.zig");
pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = smoke.fixture };
    var session: Session = .{ .model = &model, .root = ".", .io = init.io, .load_image = smoke.sampleImage, .load_cover = smoke.sampleCover };
    defer session.deinit();
    try std.Io.Dir.cwd().createDirPath(init.io, "preview");
    try smoke.start(init.gpa, init.io, &session);
    defer smoke.stop();
    try smoke.writeScreen(init.gpa, init.io, "preview/library.pgm");
    try smoke.tapText("The Copper Lantern");
    try smoke.writeScreen(init.gpa, init.io, "preview/chapters.pgm");
    try smoke.pressText("Chapter 1 - A new beginning");
    try smoke.writeScreen(init.gpa, init.io, "preview/pressed-chapter.pgm");
    const pressed_update = smoke.fake.state.updates.items[smoke.fake.state.updates.items.len - 1];
    std.debug.print("Pressed chapter update: {s} ({d},{d}) {d}x{d} px\n", .{ @tagName(pressed_update.kind), pressed_update.x, pressed_update.y, pressed_update.w, pressed_update.h });
    smoke.cancelPress();
    try smoke.tapText("Chapter 1 - A new beginning");
    try smoke.writeScreen(init.gpa, init.io, "preview/reader.pgm");
    try smoke.tapText("Aa");
    try smoke.writeScreen(init.gpa, init.io, "preview/settings.pgm");
    try smoke.tapText("Back");
    try smoke.tapText("Back");
    try smoke.tapText("Back");
    try std.Io.Dir.cwd().createDirPath(init.io, "preview/demo-data");
    var engine: @import("tachi").Engine = .init(arena.allocator(), init.io, @import("tachi").backend.none, .{ .dir = "preview/demo-data" });
    engine.execute_fn = @import("online_test.zig").fixtureExecutor;
    session.root = engine.options.dir;
    session.browser.engine = &engine;
    try smoke.tapText("Browse");
    try finish(&session);
    try smoke.writeScreen(init.gpa, init.io, "preview/sources.pgm");
    try smoke.tapText("Install / update extensions");
    try finish(&session);
    try smoke.writeScreen(init.gpa, init.io, "preview/extensions.pgm");
    try smoke.tapText("Fixture Extension");
    try finish(&session);
    try smoke.tapText("Fixture Source");
    try finish(&session);
    try smoke.writeScreen(init.gpa, init.io, "preview/browse.pgm");
    try smoke.tapText("Fixture Story");
    try finish(&session);
    try smoke.writeScreen(init.gpa, init.io, "preview/online-chapters.pgm");
    var long_book = model.library.manga[0];
    long_book.title = @import("online_test.zig").long_title;
    model.library = .{ .manga = &.{long_book} };
    engine.execute_fn = @import("online_test.zig").startingWorker;
    try smoke.tapText("Chapter 1");
    while (session.browser.busy.?.phase.load(.acquire) != .starting) try init.io.sleep(.fromMilliseconds(1), .awake);
    smoke.fake.advance(250);
    try smoke.writeScreen(init.gpa, init.io, "preview/downloading-worker-loading.pgm");
    session.browser.busy.?.cancel();
    try session.poll();
    smoke.fake.advance(250);
    engine.execute_fn = @import("online_test.zig").stalledDownload;
    session.start(.{ .download = long_book.chapters[0].id });
    _ = smoke.fake.send(.show, 0, 0);
    while (session.browser.busy.?.pages_total.load(.acquire) == 0) try init.io.sleep(.fromMilliseconds(1), .awake);
    smoke.fake.advance(250);
    try smoke.writeScreen(init.gpa, init.io, "preview/downloading.pgm");
    session.browser.busy.?.cancel();
    try session.poll();
    smoke.fake.advance(250);
    try smoke.writeScreen(init.gpa, init.io, "preview/download-canceled.pgm");
    engine.execute_fn = @import("online_test.zig").failedDownload;
    session.start(.{ .download = long_book.chapters[0].id });
    _ = smoke.fake.send(.show, 0, 0);
    try finish(&session);
    try smoke.writeScreen(init.gpa, init.io, "preview/download-failed-long-title.pgm");
    model.screen = .catalog;
    engine.execute_fn = @import("online_test.zig").startingWorker;
    session.start(.{ .browse = .{ .source = session.browser.source_id } });
    _ = smoke.fake.send(.show, 0, 0);
    while (session.browser.busy.?.phase.load(.acquire) != .starting) try init.io.sleep(.fromMilliseconds(1), .awake);
    smoke.fake.advance(250);
    try smoke.writeScreen(init.gpa, init.io, "preview/browse-worker-loading.pgm");
    session.browser.busy.?.setExtensionLoading("MangaDex");
    _ = smoke.fake.send(.show, 0, 0);
    smoke.fake.advance(250);
    try smoke.writeScreen(init.gpa, init.io, "preview/browse-extension-loading.pgm");
    session.browser.busy.?.cancel();
    try session.poll();
    try libraryScreens(init, &session, &model);
    std.debug.print("Rendered 758x1024 application screens into preview/*.pgm\n", .{});
}

/// The screens over libtachi's library views and actions, from a library
/// with categories, history, new chapters and a download queued.
fn libraryScreens(init: std.process.Init, session: *Session, model: *lib.Model) !void {
    const tachi = @import("tachi");
    const io = init.io;
    const a = model.gpa;
    const dir = "preview/demo-library";
    try std.Io.Dir.cwd().deleteTree(io, dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var engine: tachi.Engine = .init(a, io, tachi.backend.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    engine.execute_fn = @import("online_test.zig").fixtureExecutor;
    const now = std.Io.Clock.real.now(io).toMilliseconds();
    const day = std.time.ms_per_day;
    try engine.store.save(a, .{
        .manga = &.{
            .{ .id = "42:/lantern", .title = "The Copper Lantern", .cover = "demo/lantern.png", .source_id = 42, .remote = .{ .url = "/lantern", .title = "The Copper Lantern", .status = 1 }, .categories = &.{1}, .date_added = now - 30 * day, .chapters = &.{
                .{ .id = "42:/lantern/3", .title = "Chapter 3 - Embers", .number = 3, .source_order = 0, .scanlator = "Lamp Scans", .date_fetch = now - day, .date_upload = now - day, .remote = .{ .url = "/lantern/3", .name = "Chapter 3 - Embers" } },
                .{ .id = "42:/lantern/2", .title = "Chapter 2 - The long road", .number = 2, .source_order = 1, .scanlator = "Lamp Scans", .last_page_read = 4, .last_read = now - 2 * std.time.ms_per_hour, .date_fetch = now - 40 * day, .remote = .{ .url = "/lantern/2", .name = "Chapter 2 - The long road" } },
                .{ .id = "42:/lantern/1", .title = "Chapter 1 - A new beginning", .number = 1, .source_order = 2, .scanlator = "Other Group", .read = true, .last_read = now - day, .date_fetch = now - 40 * day, .remote = .{ .url = "/lantern/1", .name = "Chapter 1 - A new beginning" } },
            } },
            .{ .id = "42:/notebook", .title = "A Traveller's Notebook", .cover = "demo/notebook.png", .source_id = 42, .remote = .{ .url = "/notebook", .title = "A Traveller's Notebook", .status = 1 }, .categories = &.{2}, .next_update = now + 3 * day, .fetch_interval = 7, .chapters = &.{
                .{ .id = "42:/notebook/1", .title = "Entry 1", .number = 1, .remote = .{ .url = "/notebook/1", .name = "Entry 1" } },
            } },
            .{ .id = "local:Observatory", .title = "Stories from the Observatory", .cover = "demo/observatory.png", .categories = &.{1}, .chapters = &.{
                .{ .id = "local:Observatory/1", .title = "Night one", .pages = &.{"local/Observatory/1/1.png"} },
            } },
        },
        .categories = &.{ .{ .id = 1, .name = "Reading", .order = 0, .flags = 0x40 }, .{ .id = 2, .name = "Later", .order = 1, .flags = 0x40 } },
        .sources = &.{.{ .id = 42, .name = "Fixture Source", .lang = "en" }},
    });
    _ = try engine.queue.enqueue(&engine, &.{"42:/notebook/1"}, false);
    session.root = dir;
    session.browser.engine = &engine;
    // The engine goes with this function.
    defer session.browser.engine = null;
    model.screen = .library;
    model.offset = 0;
    try session.reloadLibrary();
    _ = smoke.fake.send(.show, 0, 0);
    smoke.fake.advance(250);
    try smoke.writeScreen(init.gpa, io, "preview/library-categories.pgm");
    for ([_][]const u8{ "Updates", "History", "Downloads", "Upcoming" }) |screen| {
        if (std.mem.eql(u8, screen, "Downloads") or std.mem.eql(u8, screen, "Upcoming")) try smoke.tapText("More");
        try smoke.tapText(if (std.mem.eql(u8, screen, "Downloads")) "Download queue" else screen);
        var name_buf: [64]u8 = undefined;
        try smoke.writeScreen(init.gpa, io, try std.fmt.bufPrint(&name_buf, "preview/{s}.pgm", .{screen}));
        if (model.screen == .queue or model.screen == .upcoming) try smoke.tapText("Back");
        try smoke.tapText("Library");
    }
    try smoke.tapText("The Copper Lantern");
    try smoke.tapText("...");
    try smoke.writeScreen(init.gpa, io, "preview/chapter-menu.pgm");
    try smoke.tapText("Back");
    try smoke.tapText("Back");
    try smoke.tapText("...");
    try smoke.writeScreen(init.gpa, io, "preview/title-menu.pgm");
    try smoke.tapText("Chapter options");
    try smoke.writeScreen(init.gpa, io, "preview/chapter-options.pgm");
    try smoke.tapText("Back");
    try smoke.tapText("Back");
    try smoke.tapText("More");
    try smoke.writeScreen(init.gpa, io, "preview/more.pgm");
    try smoke.tapText("Library settings");
    try smoke.writeScreen(init.gpa, io, "preview/library-settings.pgm");
    try smoke.tapText("Back");
    try smoke.tapText("Categories");
    try smoke.writeScreen(init.gpa, io, "preview/categories.pgm");
    try smoke.tapText("Back");
    try smoke.tapText("Backup and restore");
    try smoke.writeScreen(init.gpa, io, "preview/backup.pgm");
    try smoke.tapText("Back");
    try smoke.tapText("Statistics");
    try smoke.writeScreen(init.gpa, io, "preview/statistics.pgm");
}

fn finish(session: *Session) !void {
    const job = session.browser.busy orelse return error.NoBackgroundJob;
    job.join();
    try session.poll();
    _ = smoke.fake.send(.show, 0, 0);
    smoke.fake.advance(250);
}
