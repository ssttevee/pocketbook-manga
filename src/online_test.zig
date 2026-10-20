const std = @import("std");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const smoke = @import("smoke.zig");
const Source = tachi.models.SourceInfo;
const fixture_source: Source = .{ .id = "42", .name = "Fixture Source", .lang = "en", .supportsLatest = true, .isConfigurable = true, .className = "Fixture", .extensionPkg = "fixture.extension" };
pub fn fixtureExecutor(engine: *tachi.Engine, job: *tachi.Job) !void {
    const a = job.arena.allocator();
    try job.checkCancelled();
    switch (job.request) {
        .sources, .install, .install_file, .uninstall => job.result.sources = &.{fixture_source},
        .extensions => job.result.extensions = &.{.{ .pkg = "fixture.extension", .name = "Fixture Extension", .versionName = "1.6.1", .versionCode = 1, .libVersion = "1.6", .nsfw = false, .lang = "en", .jarUrl = "https://fixture/extension.jar", .apkUrl = "", .iconUrl = "", .supported = true, .installed = false, .installedVersionCode = null, .hasUpdate = false, .sources = &.{} }},
        .browse => |request| {
            // Query text must be copied into the job, not borrowed.
            if (request.kind == .search) try std.testing.expectEqualStrings("fixture", request.kind.search.query);
            job.result.page = .{ .mangas = &.{.{ .url = "/manga", .title = "Fixture Story" }}, .hasNextPage = false };
        },
        .add => |request| {
            const book: lib.Manga = .{ .id = "42:/manga", .title = request.manga.title, .source_id = 42, .remote = request.manga, .chapters = &.{.{ .id = "42:/chapter", .title = "Chapter 1", .remote = .{ .url = "/chapter", .name = "Chapter 1" } }} };
            try engine.store.save(a, .{ .manga = &.{book} });
            job.result = .{ .library_changed = true, .manga_id = book.id };
        },
        .download => |id| {
            const library = try engine.store.load(a);
            const updated = (try tachi.library.setPages(a, library, id, &.{ "fixture/001.png", "fixture/002.png" })) orelse return error.UnknownChapter;
            try engine.store.save(a, updated);
            job.result = .{ .library_changed = true, .manga_id = library.manga[0].id };
        },
        .preferences => job.result.preferences = &.{.{ .type = "switch", .key = "mirror", .title = "Use mirror", .value = .{ .bool = false } }},
        .set_preference => |request| {
            const prefs = try a.alloc(tachi.models.Preference, 1);
            prefs[0] = .{ .type = "switch", .key = "mirror", .title = "Use mirror", .value = request.value };
            job.result.preferences = prefs;
        },
        .update_library, .refresh => job.result.library_changed = true,
        .global_search => |request| {
            try std.testing.expectEqualStrings("Fixture Story", request.query);
            job.result.search = &.{.{ .source = fixture_source, .mangas = &.{.{ .url = "/elsewhere", .title = "Fixture Story" }} }};
        },
        .migrate => |request| {
            const library = try engine.store.load(a);
            const titles = try a.dupe(lib.Manga, library.manga);
            for (titles) |*m| if (std.mem.eql(u8, m.id, request.from)) {
                m.favorite = false;
            };
            const moved: lib.Manga = .{ .id = "42:/elsewhere", .title = "Fixture Story", .source_id = 42, .remote = request.manga };
            try engine.store.save(a, .{ .manga = try std.mem.concat(a, lib.Manga, &.{ titles, &.{moved} }) });
            job.result = .{ .library_changed = true, .manga_id = moved.id };
        },
        else => return error.FixtureFailure,
    }
}
fn finish(session: *Session) !void {
    const job = session.browser.busy orelse return error.NoBackgroundJob;
    job.join();
    smoke.fake.advance(250);
    try std.testing.expect(session.browser.busy == null);
    try std.testing.expect(!std.mem.startsWith(u8, session.status, "error"));
}
test "device UI installs a source, searches, adds and downloads a chapter, reads and configures it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = fixtureExecutor;
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root, .load_image = smoke.sampleImage };
    session.browser.engine = &engine;
    defer session.deinit();
    try smoke.start(std.testing.allocator, std.testing.io, &session);
    defer smoke.stop();
    try smoke.tapText("Browse");
    try finish(&session);
    try smoke.tapText("Install / update extensions");
    try finish(&session);
    try smoke.tapText("Fixture Extension");
    try finish(&session);
    try smoke.tapText("Fixture Source");
    try finish(&session);
    try smoke.tapText("Search this source");
    smoke.fake.keyboardResult("fixture");
    smoke.fake.advance(1);
    try smoke.tapText("Search");
    try finish(&session);
    try smoke.tapText("Fixture Story");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    try std.testing.expectEqual(0, model.library.manga[0].chapters[0].pages.len);
    try smoke.tapText("Chapter 1");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
    _ = smoke.fake.pressKey(.next);
    try std.testing.expectEqual(1, model.page);
    try std.testing.expect(model.readState(model.library.manga[0].chapters[0]).read);
    try smoke.tapText("Back");
    try smoke.tapText("Refresh chapters");
    try finish(&session);
    // The reload came from libtachi's store: progress was recorded there.
    try std.testing.expect(model.library.manga[0].chapters[0].read);
    try smoke.tapText("Back");
    try smoke.tapText("Browse");
    try finish(&session);
    try smoke.tapText("Fixture Source");
    try finish(&session);
    try smoke.tapText("Source settings");
    try finish(&session);
    try smoke.tapText("Use mirror");
    try finish(&session);
    try std.testing.expect(session.browser.preferences.?.result.preferences[0].value.?.bool);
    // Pinning and hiding are libtachi's source settings.
    try smoke.tapText("Pin");
    try std.testing.expectEqualSlices(i64, &.{42}, (try engine.loadSettings(a)).browse.pinned_sources);
    try smoke.tapText("Hide");
    try std.testing.expectEqual(0, session.browser.source_rows.len);
    try std.testing.expectEqual(42, (try engine.loadSettings(a)).browse.last_source);
}
test "background failures are reported and leave library and progress intact" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var engine: tachi.Engine = .init(arena.allocator(), std.testing.io, tachi.backend.none, .{ .dir = "." });
    engine.execute_fn = fixtureExecutor;
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = smoke.fixture };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    session.browser.engine = &engine;
    defer session.deinit();
    session.start(.scan_local);
    session.browser.busy.?.join();
    try session.poll();
    try std.testing.expect(std.mem.startsWith(u8, session.status, "FixtureFailure"));
    try std.testing.expectEqual(3, model.library.manga.len);
    try std.testing.expect(session.browser.busy == null);
}

pub fn failedDownload(_: *tachi.Engine, job: *tachi.Job) !void {
    job.pages_done.store(1, .release);
    job.pages_total.store(3, .release);
    return error.NetworkDisconnected;
}
test "download failure stays visible with progress and resume instructions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var engine: tachi.Engine = .init(arena.allocator(), std.testing.io, tachi.backend.none, .{ .dir = "." });
    engine.execute_fn = failedDownload;
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = smoke.fixture, .screen = .chapters };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    session.browser.engine = &engine;
    defer session.deinit();
    var book = smoke.fixture.manga[0];
    book.title = long_title;
    model.library = .{ .manga = &.{book} };
    session.start(.{ .download = book.chapters[0].id });
    session.browser.busy.?.join();
    try session.poll();
    try std.testing.expect(session.download_error);
    try std.testing.expect(std.mem.indexOf(u8, session.status, "1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.status, "NetworkDisconnected") != null);
    // The headline carries the outcome and the resume hint, so the detail repeats neither.
    try std.testing.expect(std.mem.indexOf(u8, session.status, "Download failed") == null);
    try session.poll();
    try std.testing.expect(session.download_error);
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    var harness: @import("fabrum").app.testing.Harness(.{}, @import("ui.zig")) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{@import("fabrum").app.RootValue.of(&session)}, .widgets = .drawn });
    defer harness.deinit();
    try harness.frame();
    try harness.expectText("Download failed - tap chapter to resume");
    try harness.expectText(session.status);
    const label = harness.findText("Download failed - tap chapter to resume").?;
    const detail = harness.findText(session.status).?;
    try std.testing.expect(detail.bbox.y + detail.bbox.h - label.bbox.y < 65);
    try harness.expectText(book.title);
    try harness.expectText(book.chapters[0].title);
}

test "online rows use fabrum pressed state and small partial updates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = fixtureExecutor;
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root };
    session.browser.engine = &engine;
    defer session.deinit();
    try smoke.start(std.testing.allocator, std.testing.io, &session);
    defer smoke.stop();
    try smoke.tapText("Browse");
    try finish(&session);
    try smoke.expectRowFeedback("Fixture Source");
    try smoke.tapText("Install / update extensions");
    try finish(&session);
    try smoke.expectRowFeedback("Fixture Extension");
    try smoke.tapText("Fixture Extension");
    try finish(&session);
    try smoke.tapText("Fixture Source");
    try finish(&session);
    try smoke.expectRowFeedback("Fixture Story");
    try smoke.tapText("Source settings");
    try finish(&session);
    try smoke.expectRowFeedback("Use mirror");
    try smoke.tapText("Aa");
    try smoke.expectRowFeedback("Right to left (manga)");
}

pub fn stalledDownload(engine: *tachi.Engine, job: *tachi.Job) !void {
    job.pages_done.store(4, .release);
    job.pages_total.store(12, .release);
    try engine.io.sleep(.fromSeconds(60), .awake);
}
test "downloading and cancellation keep the selected series and chapter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = "." });
    engine.execute_fn = stalledDownload;
    var model: lib.Model = .{ .gpa = a, .library = smoke.fixture };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    session.browser.engine = &engine;
    defer session.deinit();
    const book = smoke.fixture.manga[0];
    session.start(.{ .download = book.chapters[0].id });
    while (session.browser.busy.?.pages_total.load(.acquire) == 0) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    var harness: @import("fabrum").app.testing.Harness(.{}, @import("ui.zig")) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{@import("fabrum").app.RootValue.of(&session)}, .widgets = .drawn });
    defer harness.deinit();
    try harness.frame();
    try harness.expectText("Downloading chapter");
    try harness.expectText(book.title);
    try harness.expectText(book.chapters[0].title);
    try harness.expectText("4 / 12 pages");
    session.browser.busy.?.cancel();
    try session.poll();
    try harness.frame();
    try harness.expectText("Download canceled - tap chapter to resume");
    try harness.expectText(book.title);
    try harness.expectText(book.chapters[0].title);
    try std.testing.expect(std.mem.indexOf(u8, session.status, "4/12") != null);
}

pub const long_title = "Reincarnated as the Villainous Orphanage Director Destined to Be Defeated, I Ended Up Being Loved by the Main Heroines' Daughters";
pub fn startingWorker(engine: *tachi.Engine, job: *tachi.Job) !void {
    job.setPhase(.starting);
    var ready: std.Io.Event = .unset;
    try ready.wait(engine.io);
}
test "worker startup is shown for downloads and browse and remains immediately cancelable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = "." });
    engine.execute_fn = startingWorker;
    var book = smoke.fixture.manga[0];
    book.title = long_title;
    var model: lib.Model = .{ .gpa = a, .library = .{ .manga = &.{book} }, .screen = .chapters };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    session.browser.engine = &engine;
    defer session.deinit();
    var harness: @import("fabrum").app.testing.Harness(.{}, @import("ui.zig")) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{@import("fabrum").app.RootValue.of(&session)}, .widgets = .drawn });
    defer harness.deinit();
    const requests: []const tachi.engine.Request = &.{ .{ .download = book.chapters[0].id }, .sources, .{ .browse = .{ .source = 42 } }, .{ .preferences = 42 } };
    for (requests) |request| {
        session.start(request);
        const job = session.browser.busy.?;
        while (job.phase.load(.acquire) != .starting) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        try harness.frame();
        try harness.expectText("Loading libtachi worker... (this may take a minute)");
        try harness.expectText("Cancel");
        job.setExtensionLoading("MangaDex");
        try harness.frame();
        try harness.expectNoText("Loading libtachi worker... (this may take a minute)");
        try harness.expectText("Loading MangaDex extension...");
        if (request == .download) {
            job.setPhase(.operation);
            try harness.frame();
            try harness.expectNoText("Loading MangaDex extension...");
            try harness.expectText("Fetching page list");
        }
        const started = tachi.worker.tachi_now_ms();
        job.cancel();
        try std.testing.expect(tachi.worker.tachi_now_ms() - started < 500);
        try session.poll();
    }
}

test "device UI migrates a title to another source through a global search" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = fixtureExecutor;
    try engine.store.save(a, .{ .manga = &.{.{ .id = "42:/manga", .title = "Fixture Story", .source_id = 42, .remote = .{ .url = "/manga", .title = "Fixture Story" } }} });
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.reloadLibrary();
    try smoke.start(std.testing.allocator, std.testing.io, &session);
    defer smoke.stop();
    try smoke.tapText("...");
    try smoke.tapText("Migrate to another source");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.global_search, model.screen);
    try smoke.tapText("Fixture Source");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    try std.testing.expectEqualStrings("42:/elsewhere", model.library.manga[model.manga].id);
    try std.testing.expect(session.browser.migrate_from == null);
}
