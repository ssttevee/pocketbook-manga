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
        .read => job.result.pages = &.{ "cache/chapters/pages/1.png", "cache/chapters/pages/2.png" },
        .tracker => |c| switch (c.operation) {
            .login => |l| {
                var state = (try engine.loadTrackers(a)).*;
                try state.putCredential(a, .{ .tracker_id = c.id, .username = "42", .password = l.password, .display_name = l.username });
                try state.save(a, engine.io, engine.options.dir);
            },
            .search => job.result.tracking_reply = .{ .matches = &.{.{ .track = .{ .tracker_id = c.id, .remote_id = 9, .title = "Fixture Story", .total_chapters = 12 }, .publishing_type = "Manga" }} },
            else => return error.FixtureFailure,
        },
        .track_bind => |c| {
            const library = try engine.store.load(a);
            const titles = try a.dupe(lib.Manga, library.manga);
            for (titles) |*m| if (std.mem.eql(u8, m.id, c.manga_id)) {
                m.tracks = try a.dupe(tachi.library.Track, &.{c.track});
            };
            var next = library;
            next.manga = titles;
            try engine.store.save(a, next);
            job.result.library_changed = true;
        },
        .add_store => |url| {
            const file = try tachi.stores.File.load(a, engine.io, engine.options.dir);
            try (try file.upsert(a, .{ .index_url = url, .name = "Fixture Store" })).save(a, engine.io, engine.options.dir);
        },
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
    try smoke.tapText("Extensions");
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
    smoke.fake.tap(170, 12);
    smoke.fake.advance(1);
    try smoke.tapText("Back");
    try smoke.tapText("Refresh chapters");
    try finish(&session);
    // The reload came from libtachi's store: progress was recorded there.
    try std.testing.expect(model.library.manga[0].chapters[0].read);
    try smoke.tapText("Back");
    try smoke.tapText("Browse");
    if (session.browser.busy != null) try finish(&session);
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
    try smoke.tapText("Show");
    // Last used, and again among the pinned, as Mihon lists it.
    try std.testing.expectEqual(2, session.browser.source_rows.len);
    try smoke.tapText("Back");
    try smoke.tapText("Languages");
    try smoke.tapText("[x] en");
    try std.testing.expectEqual(0, session.browser.source_rows.len);
    try std.testing.expect(!session.browser.languages[0].enabled);
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
test "download failure stays visible with saved progress and no resume promise" {
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
    // The headline carries the outcome; the chapter row owns resumability.
    try std.testing.expect(std.mem.indexOf(u8, session.status, "Download failed") == null);
    try session.poll();
    try std.testing.expect(session.download_error);
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    var harness: @import("fabrum").app.testing.Harness(.{}, @import("ui.zig")) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{@import("fabrum").app.RootValue.of(&session)}, .widgets = .drawn });
    defer harness.deinit();
    try harness.frame();
    try harness.expectText("Download failed");
    try harness.expectText(session.status);
    const label = harness.findText("Download failed").?;
    const detail = harness.findText(session.status).?;
    try std.testing.expect(detail.bbox.y + detail.bbox.h - label.bbox.y < 65);
    try std.testing.expect(harness.findElement(harness.root().element("series-title")) != null);
    try harness.expectText(book.chapters[0].title);
    try harness.click("Dismiss");
    try std.testing.expect(!session.download_error);
    try std.testing.expect(!session.download_blocked);
    try std.testing.expectEqualStrings("", session.status);
    try harness.expectNoText("Download failed");
    try std.testing.expect(session.download_identity == null);
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
    try smoke.tapText("Extensions");
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
    try harness.expectText("Download paused");
    try std.testing.expectEqualStrings(book.title, session.download_identity.?.series);
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
            try harness.expectText(long_title);
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
    try smoke.tapText("Migrate");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.global_search, model.screen);
    try smoke.tapText("Fixture Source");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    try std.testing.expectEqualStrings("42:/elsewhere", model.library.manga[model.manga].id);
    try std.testing.expect(session.browser.migrate_from == null);
}

test "device UI reads a chapter online through libtachi's chapter cache" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = fixtureExecutor;
    try engine.store.save(a, .{ .manga = &.{.{ .id = "42:/manga", .title = "Fixture Story", .source_id = 42, .remote = .{ .url = "/manga", .title = "Fixture Story" }, .chapters = &.{
        .{ .id = "42:/chapter", .title = "Chapter 1", .remote = .{ .url = "/chapter", .name = "Chapter 1" } },
    } }} });
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.reloadLibrary();
    try smoke.start(std.testing.allocator, std.testing.io, &session);
    defer smoke.stop();
    try smoke.tapText("Fixture Story");
    try smoke.tapText("...");
    try smoke.tapText("Read online");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
    try std.testing.expectEqual(2, model.current().?.pages.len);
    // Still not a download.
    try std.testing.expectEqual(0, model.library.manga[0].chapters[0].pages.len);
}

test "device UI asks before adding a title the library may already have" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = fixtureExecutor;
    try engine.store.save(a, .{ .manga = &.{.{ .id = "7:/other", .title = "Fixture Story", .source_id = 7 }} });
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.reloadLibrary();
    try smoke.start(std.testing.allocator, std.testing.io, &session);
    defer smoke.stop();
    try smoke.tapText("Browse");
    if (session.browser.busy != null) try finish(&session);
    try smoke.tapText("Fixture Source");
    try finish(&session);
    try smoke.tapText("Fixture Story");
    try std.testing.expectEqual(lib.Screen.duplicate, model.screen);
    try smoke.tapText("Add anyway");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
}

test "device UI adds and removes an extension store" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
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
    try smoke.tapText("Extensions");
    try finish(&session);
    try smoke.tapText("Extension stores");
    try std.testing.expectEqual(lib.Screen.stores, model.screen);
    try smoke.tapText("Add a store by its index URL");
    smoke.fake.keyboardResult("https://fixture/index.min.json");
    smoke.fake.advance(1);
    try finish(&session);
    try std.testing.expectEqual(1, session.stores.len);
    try std.testing.expectEqualStrings("Fixture Store", session.stores[0].name);
    try smoke.tapText("Remove");
    try std.testing.expectEqual(0, session.stores.len);
}

test "device UI logs in to a tracker and tracks a title" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = fixtureExecutor;
    try engine.store.save(a, .{ .manga = &.{.{ .id = "42:/manga", .title = "Fixture Story", .source_id = 42 }} });
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.reloadLibrary();
    try smoke.start(std.testing.allocator, std.testing.io, &session);
    defer smoke.stop();
    try smoke.tapText("More");
    try smoke.tapText("Trackers");
    try smoke.tapText("Log in");
    try std.testing.expectEqual(lib.Screen.tracker_login, model.screen);
    try smoke.tapText("Username");
    smoke.fake.keyboardResult("reader");
    smoke.fake.advance(1);
    try smoke.tapText("Password (logs in)");
    smoke.fake.keyboardResult("secret");
    smoke.fake.advance(1);
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.trackers, model.screen);
    try std.testing.expect(session.trackers.loggedIn(1));
    try smoke.tapText("Back");
    try smoke.tapText("Library");
    try smoke.tapText("...");
    try smoke.tapText("Tracking");
    try smoke.tapText("Find");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.track_search, model.screen);
    try smoke.tapText("Fixture Story");
    try finish(&session);
    try std.testing.expectEqual(lib.Screen.tracking, model.screen);
    try std.testing.expectEqual(9, model.library.manga[0].tracks[0].remote_id);
}

fn blockedDownload(_: *tachi.Engine, job: *tachi.Job) !void {
    job.pages_done.store(1, .release);
    job.pages_total.store(3, .release);
    return error.BrowserVerificationRequired;
}

test "unsupported browser verification explains alternatives instead of offering resume" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = "." });
    engine.execute_fn = blockedDownload;
    var model: lib.Model = .{ .gpa = a, .library = smoke.fixture, .screen = .chapters };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    session.browser.engine = &engine;
    defer session.deinit();
    session.start(.{ .download = smoke.fixture.manga[0].chapters[0].id });
    session.browser.busy.?.join();
    try session.poll();
    try std.testing.expect(session.download_blocked);
    try std.testing.expect(std.mem.indexOf(u8, session.status, "1/3 pages saved") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.status, @import("session.zig").verification_alternative) != null);
    var h: @import("fabrum").app.testing.Harness(.{}, @import("ui.zig")) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{@import("fabrum").app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.expectText("Cannot download from this source");
    try h.expectNoText("Download failed");
    const detail = h.findText(session.status).?;
    try std.testing.expect(detail.bbox.h > 30);
    try std.testing.expect(detail.bbox.y + detail.bbox.h < 464);
    // A subsequent temporary failure must regain the ordinary resume path.
    engine.execute_fn = failedDownload;
    session.start(.{ .download = smoke.fixture.manga[0].chapters[0].id });
    session.browser.busy.?.join();
    try session.poll();
    try std.testing.expect(!session.download_blocked);
}

test "blocked queue guidance fits and its title searches alternatives without migrating" {
    const f = @import("fabrum");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = fixtureExecutor;
    var book = smoke.fixture.manga[0];
    book.title = "Fixture Story";
    var model: lib.Model = .{ .gpa = a, .library = .{ .manga = &.{book} }, .screen = .queue, .feed_count = 5 };
    var feed: [5]@import("session.zig").FeedRow = undefined;
    for (&feed, 0..) |*row, i| row.* = .{ .pick = .{ .manga = 0, .chapter = 0 }, .title = try std.fmt.allocPrint(a, "Blocked title {d}", .{i}), .detail = "Cannot download: browser verification", .blocked = true };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root, .feed = &feed };
    session.browser.engine = &engine;
    session.browser.migrate_from = try a.dupe(u8, book.id);
    defer session.deinit();
    var h: f.app.testing.Harness(.{}, @import("ui.zig")) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.expectText("Some chapters cannot be downloaded");
    try h.expectText(@import("session.zig").verification_explanation);
    const last = h.findText("Blocked title 3").?;
    const pager = h.findText("Next").?;
    try std.testing.expect(last.bbox.y + last.bbox.h <= pager.bbox.y);
    try std.testing.expect(pager.bbox.y + pager.bbox.h <= 464);
    // The model and view must advance by the same number of rows.
    try model.dispatch(.{ .list_page = 1 });
    try std.testing.expectEqual(4, model.offset);
    model.offset = 0;
    try h.click("Blocked title 0");
    try std.testing.expectEqual(lib.Screen.global_search, model.screen);
    try std.testing.expect(session.browser.migrate_from == null);
    const job = session.browser.busy.?;
    try std.testing.expectEqualStrings("Fixture Story", job.request.global_search.query);
    job.join();
    try session.poll();
}

test "restored blocked queue entries become actionable rows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.queue.deinit(&engine);
    const book: lib.Manga = .{ .id = "42:/story", .title = "Fixture Story", .source_id = 42, .chapters = &.{.{ .id = "42:/chapter", .title = "Chapter 1" }} };
    const library: lib.Library = .{ .manga = &.{book} };
    try engine.store.save(a, library);
    try tmp.dir.createDirPath(std.testing.io, "downloads");
    try tachi.library.writeJsonAtomic(a, std.testing.io, try std.fs.path.join(a, &.{ root, "downloads/queue.json" }), .{
        .chapters = &.{"42:/chapter"},
        .browser_verification_required = &.{.{ .chapter_id = "42:/chapter", .failure = "BrowserVerificationRequired: Cloudflare challenge on images.example" }},
    });
    var model: lib.Model = .{ .gpa = a, .library = library, .screen = .queue };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.refreshFeed();
    try std.testing.expectEqual(1, session.feed.len);
    try std.testing.expect(session.feed[0].blocked);
    try std.testing.expect(std.mem.startsWith(u8, session.feed[0].detail, "Cannot download: browser verification"));
    try std.testing.expectEqualStrings("Fixture Story", session.feed[0].title);
    try std.testing.expect(!@import("session.zig").browserVerificationRequired("ExtensionError: HTTP error 403"));
    try std.testing.expect(!@import("session.zig").browserVerificationRequired("BrowserVerificationRequiredButDifferent"));
}

test "queue controls show a paused queue and only its applicable action" {
    const f = @import("fabrum");
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = smoke.fixture, .screen = .queue, .feed_count = 1 };
    const feed: []const @import("session.zig").FeedRow = &.{.{ .pick = .{ .manga = 0, .chapter = 0 }, .title = "Queued title", .detail = "Queued" }};
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = ".", .feed = feed };
    var h: f.app.testing.Harness(.{}, @import("ui.zig")) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.expectText("Queue paused");
    try h.expectText("Start");
    try std.testing.expect(h.findText("Stop") == null);
    session.feed = &.{};
    model.feed_count = 0;
    try h.frame();
    try h.expectText("Queue empty");
    try std.testing.expect(h.findText("Start") == null);
    try std.testing.expect(h.findText("Stop") == null);
}

test "entering reading releases a retained worker after background downloads finish" {
    const Backend = tachi.backend.Backend;
    const Fake = struct {
        warm: bool = true,
        releases: usize = 0,
        fn run(_: *anyopaque, _: std.mem.Allocator, _: tachi.backend.Call, _: ?tachi.backend.Status) anyerror!tachi.backend.Reply {
            return error.NoBackend;
        }
        fn ready(ptr: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.warm;
        }
        fn release(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.releases += 1;
            self.warm = false;
        }
        fn quiet(_: *anyopaque) void {}
    };
    var fake: Fake = .{};
    const backend: Backend = .{ .ptr = &fake, .vtable = &.{ .run = Fake.run, .warm = Fake.ready, .cancel = Fake.quiet, .release = Fake.release, .idle = Fake.quiet } };
    var engine: tachi.Engine = .init(std.testing.allocator, std.testing.io, backend, .{ .dir = "." });
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = smoke.fixture, .screen = .reader };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    session.browser.engine = &engine;
    // A runner is active until its completion flag is published; no actual task is awaited.
    engine.queue.runner = .{ .any_future = null, .result = {} };
    engine.queue.paused = false;
    try session.poll();
    try std.testing.expectEqual(0, fake.releases);
    engine.queue.runner = null;
    try session.poll();
    try std.testing.expectEqual(1, fake.releases);
    try session.poll();
    try std.testing.expectEqual(1, fake.releases);
}

fn failedBeforePageList(_: *tachi.Engine, _: *tachi.Job) !void {
    return error.NetworkDisconnected;
}

test "failure before the page list never invents saved page counts or resume advice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = failedBeforePageList;
    var model: lib.Model = .{ .gpa = a, .library = smoke.fixture, .screen = .chapters };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    session.start(.{ .download = smoke.fixture.manga[0].chapters[0].id });
    session.browser.busy.?.join();
    try session.poll();
    try std.testing.expectEqualStrings("NetworkDisconnected", session.status);
    var h: @import("fabrum").app.testing.Harness(.{}, @import("ui.zig")) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{@import("fabrum").app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.expectText("Download failed");
    try h.expectNoText("0/0 pages saved");
    try h.expectNoText("tap chapter to resume");
}

fn savePartialAndWait(engine: *tachi.Engine, job: *tachi.Job) !void {
    const a = job.arena.allocator();
    const id = job.request.download;
    const folder = try std.fmt.allocPrint(a, "downloads/{x}", .{std.hash.Wyhash.hash(0, id)});
    var dir = try std.Io.Dir.cwd().openDir(engine.io, engine.options.dir, .{});
    defer dir.close(engine.io);
    try dir.createDirPath(engine.io, try std.fs.path.join(a, &.{ folder, "1" }));
    try dir.writeFile(engine.io, .{ .sub_path = try std.fs.path.join(a, &.{ folder, "current-plan.json" }), .data = "{\"plan\":\"1\",\"total\":12}" });
    for (1..4) |i| try dir.writeFile(engine.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/1/{d:0>4}.png", .{ folder, i }), .data = "\x89PNG\r\n\x1a\nfixture" });
    job.pages_done.store(3, .release);
    job.pages_total.store(12, .release);
    var waiting: std.Io.Event = .unset;
    try waiting.wait(engine.io);
}

test "canceling a partial download refreshes its chapter row without leaving the series" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = savePartialAndWait;
    const book: lib.Manga = .{ .id = "series", .title = "Story", .source_id = 42, .chapters = &.{.{ .id = "chapter", .title = "Chapter 1" }} };
    var model: lib.Model = .{ .gpa = a, .library = .{ .manga = &.{book} }, .screen = .chapters };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.refreshRows();
    try std.testing.expect(session.chapter_downloads[0] == null);
    session.start(.{ .download = "chapter" });
    while (session.browser.busy.?.pages_total.load(.acquire) == 0) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    session.browser.busy.?.cancel();
    try session.poll();
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    try std.testing.expectEqual(@as(usize, 3), session.chapter_downloads[0].?.done);
    var h: @import("fabrum").app.testing.Harness(.{}, @import("ui.zig")) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{@import("fabrum").app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Dismiss");
    try h.expectText("Unread · Download paused 3/12 · Tap to resume");
}
