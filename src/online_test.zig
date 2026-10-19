const std = @import("std");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const online = @import("online.zig");
const smoke = @import("smoke.zig");
const Source = @import("tachi").models.SourceInfo;
const fixture_source: Source = .{ .id = "42", .name = "Fixture Source", .lang = "en", .supportsLatest = true, .isConfigurable = true, .className = "Fixture", .extensionPkg = "fixture.extension" };
pub fn fixtureExecutor(engine: *online.Engine, job: *online.Job) !void {
    const a = job.arena.allocator();
    try job.checkCancelled();
    switch (job.request) {
        .sources, .install, .uninstall => job.result.sources = &.{fixture_source},
        .extensions => job.result.extensions = &.{.{ .pkg = "fixture.extension", .name = "Fixture Extension", .versionName = "1.6.1", .versionCode = 1, .libVersion = "1.6", .nsfw = false, .lang = "en", .jarUrl = "https://fixture/extension.jar", .apkUrl = "", .iconUrl = "", .supported = true, .installed = false, .installedVersionCode = null, .hasUpdate = false, .sources = &.{} }},
        .titles => |request| {
            // Query text must be copied into the worker request, not borrowed.
            if (request.query.len > 0) try std.testing.expectEqualStrings("fixture", request.query);
            job.result.titles = .{ .mangas = &.{.{ .url = "/manga", .title = "Fixture Story" }}, .hasNextPage = false };
        },
        .add => |request| {
            const book: lib.Manga = .{ .id = "42:/manga", .title = request.manga.title, .source_id = 42, .remote = request.manga, .chapters = &.{.{ .id = "42:/chapter", .title = "Chapter 1", .remote = .{ .url = "/chapter", .name = "Chapter 1" } }} };
            const path = try std.fs.path.join(a, &.{ engine.root, "library.json" });
            try lib.writeJson(a, engine.io, path, lib.Library{ .manga = &.{book} });
            job.result = .{ .library_changed = true, .open_id = book.id };
        },
        .download => |request| {
            var book = request.book;
            var chapter = request.chapter;
            chapter.pages = &.{ "fixture/001.png", "fixture/002.png" };
            book.chapters = &.{chapter};
            const path = try std.fs.path.join(a, &.{ engine.root, "library.json" });
            try lib.writeJson(a, engine.io, path, lib.Library{ .manga = &.{book} });
            job.result = .{ .library_changed = true, .open_id = book.id };
        },
        .preferences => job.result.preferences = &.{.{ .type = "switch", .key = "mirror", .title = "Use mirror", .value = .{ .bool = false } }},
        .set_preference => |request| {
            const prefs = try a.alloc(@import("tachi").models.Preference, 1);
            prefs[0] = .{ .type = "switch", .key = "mirror", .title = "Use mirror", .value = request.value };
            job.result.preferences = prefs;
        },
        .update_all, .refresh => job.result.library_changed = true,
        .scan => return error.FixtureFailure,
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
    var engine: online.Engine = .{ .gpa = a, .io = std.testing.io, .root = root, .execute_fn = fixtureExecutor };
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
    try std.testing.expect(model.progress("42:/chapter").?.completed);
    try smoke.tapText("Back");
    try smoke.tapText("Refresh chapters");
    try finish(&session);
    try std.testing.expect(model.progress("42:/chapter").?.completed);
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
}
test "background failures are reported and leave library and progress intact" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var engine: online.Engine = .{ .gpa = arena.allocator(), .io = std.testing.io, .root = ".", .execute_fn = fixtureExecutor };
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = smoke.fixture };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    session.browser.engine = &engine;
    defer session.deinit();
    session.start(.scan);
    session.browser.busy.?.join();
    try session.poll();
    try std.testing.expect(std.mem.startsWith(u8, session.status, "FixtureFailure"));
    try std.testing.expectEqual(3, model.library.manga.len);
    try std.testing.expect(session.browser.busy == null);
}
