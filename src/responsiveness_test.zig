const std = @import("std");
const f = @import("fabrum");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @import("ui.zig");
const Harness = f.app.testing.Harness(.{}, Root);

test "Browse startup allows switching tabs and returning without restarting the worker task" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    engine.execute_fn = @import("online_test.zig").startingWorker;
    try engine.store.save(a, .{});
    var model: lib.Model = .{ .gpa = a, .screen = .sources };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root };
    session.browser.engine = &engine;
    defer session.deinit();
    session.start(.sources);
    const job = session.browser.busy.?;
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.clickElement(h.root().element("library"));
    try std.testing.expectEqual(lib.Screen.library, model.screen);
    try std.testing.expect(session.browser.busy == null);
    try std.testing.expect(session.browser.loading_sources == job);
    try h.expectNoText("Loading libtachi worker... (this may take a minute)");
    try h.clickElement(h.root().element("browse"));
    try std.testing.expectEqual(lib.Screen.sources, model.screen);
    try std.testing.expect(session.browser.busy == job);
    try h.clickElement(h.root().element("more"));
    try std.testing.expectEqual(lib.Screen.settings, model.screen);
    // A late result is collected without navigating away from the user's tab.
    job.cancel();
    job.join();
    try session.poll();
    try std.testing.expectEqual(lib.Screen.settings, model.screen);
    try std.testing.expect(session.browser.loading_sources == null);
}

test "download queue uses available viewport rows and reserves warning space" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model: lib.Model = .{ .gpa = a, .screen = .queue };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    defer session.deinit();
    var rows: [30]@import("session.zig").FeedRow = undefined;
    for (&rows, 0..) |*row, i| row.* = .{ .pick = .{ .manga = 0, .chapter = 0 }, .title = try std.fmt.allocPrint(a, "Queued {d}", .{i}), .detail = "Chapter / Queued" };
    session.feed = &rows;
    model.feed_count = rows.len;
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 700), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    const roomy = model.pageRows();
    try std.testing.expect(roomy > 4);
    const last = h.findText(rows[roomy - 1].title).?;
    const pager = h.findElement(h.root().element("next-feed")).?;
    try std.testing.expect(last.bbox.y + last.bbox.h <= pager.bbox.y);
    // Measure the full row, including its detail line and padding.
    const units = h.runtime.context().units.items;
    const last_row = units[units[last.parent].parent].bbox;
    try std.testing.expect(pager.bbox.y - (last_row.y + last_row.h) < 41);
    rows[0].blocked = true;
    try h.frame();
    try std.testing.expect(model.pageRows() < roomy);
    const next = h.findElement(h.root().element("next-feed")).?;
    try std.testing.expect(next.bbox.y + next.bbox.h <= 700);
    const warning_rows = model.pageRows();
    session.setStatus("The chapter could not be downloaded.");
    session.download_error = true;
    try h.frame();
    try std.testing.expect(model.pageRows() < warning_rows);
    const error_pager = h.findElement(h.root().element("next-feed")).?;
    try std.testing.expect(error_pager.bbox.y + error_pager.bbox.h <= 700);
    try h.clickElement(h.root().element("dismiss-download-error"));
    try std.testing.expectEqual(warning_rows, model.pageRows());
}

test "root tabs paint loading before database tasks and discard superseded views" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.queue.deinit(&engine);
    const library: lib.Library = .{ .manga = &.{.{ .id = "story", .title = "Story", .chapters = &.{.{ .id = "chapter", .title = "Chapter", .last_read = 1 }} }} };
    try engine.store.save(a, library);
    var model: lib.Model = .{ .gpa = a, .library = library };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root };
    session.browser.engine = &engine;
    defer session.deinit();
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.clickElement(h.root().element("history"));
    try std.testing.expectEqual(lib.Screen.history, model.screen);
    try h.expectText("Loading…");
    try std.testing.expectEqual(@as(usize, 0), session.feed.len);
    const first = session.tab_request.?;
    // A second destination is interactive while the first task is still queued.
    try h.clickElement(h.root().element("updates"));
    try std.testing.expectEqual(lib.Screen.updates, model.screen);
    try h.expectText("Loading…");
    const current = session.tab_request.?;
    try @import("tab_data.zig").accept(&session, .{ .request = first, .category = 0, .category_id = 0, .categories = &.{}, .titles = &.{}, .feed = &.{} });
    try std.testing.expectEqual(current.generation, session.tab_request.?.generation);
    // A failure already queued before navigation has the same stale-generation
    // protection as a successful result, independently of task cancellation.
    try h.post(h.root().handler(Root, .tab_loaded), @import("tab_data.zig").Outcome{ .request = first, .value = error.AccessDenied });
    try std.testing.expectEqual(current.generation, session.tab_request.?.generation);
    try std.testing.expectEqualStrings("", session.status);
    try h.expectText("Loading…");
    try h.runTasks();
    try std.testing.expect(session.tab_request == null);
    try h.expectNoText("Loading…");
    try h.clickElement(h.root().element("history"));
    try h.expectText("Loading…");
    try h.runTasks();
    try std.testing.expectEqual(@as(usize, 1), session.feed.len);
    try std.testing.expectEqualStrings("Story", session.feed[0].title);
    try h.clickElement(h.root().element("library"));
    try h.expectText("Loading…");
    try h.runTasks();
    try h.expectText("Story");
    try h.clickElement(h.root().element("history"));
    try h.clickElement(h.root().element("more"));
    try h.expectText("Download queue");
    try h.runTasks();
    try std.testing.expectEqual(lib.Screen.settings, model.screen);
    try h.expectNoText("Loading…");
}
