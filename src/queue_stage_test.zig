const std = @import("std");
const f = @import("fabrum");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @import("ui.zig");

test "queue separates listing cached plans and transfers and shows paused chapter progress" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{ .manga = &.{.{ .id = "series", .title = "Story", .source_id = 1, .chapters = &.{.{ .id = "chapter", .title = "Chapter 1" }} }} });
    _ = try engine.queue.enqueue(&engine, &.{"chapter"}, false);
    var model: lib.Model = .{ .gpa = a, .screen = .queue };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    try session.reloadLibrary();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    var job: tachi.Job = .{ .arena = .init(a), .engine = &engine, .request = .{ .download = "chapter" } };
    defer job.arena.deinit();
    // Simulate stable scheduler snapshots without launching network threads.
    // Listing is a distinct stage even if a prior plan supplied a page count.
    const item = &engine.queue.items.items[0];
    item.status = .downloading;
    item.planning = true;
    item.job = &job;
    job.pages_total.store(12, .release);
    for ([_]struct { phase: tachi.engine.Phase, label: []const u8 }{
        .{ .phase = .starting, .label = "Chapter 1  /  Loading worker" },
        .{ .phase = .extension_loading, .label = "Chapter 1  /  Loading extension" },
        .{ .phase = .operation, .label = "Chapter 1  /  Listing pages" },
    }) |step| {
        job.phase.store(step.phase, .release);
        try session.refreshFeed();
        try h.frame();
        try h.expectText(step.label);
        try h.expectNoText("Downloading 0/0");
    }
    item.job = null;
    item.planning = false;
    item.prepared = true;
    item.status = .queued;
    item.pages_total = 12;
    try session.refreshFeed();
    try h.frame();
    try h.expectText("Chapter 1  /  Pages ready");
    item.status = .downloading;
    item.pages_done = 3;
    try session.refreshFeed();
    try h.frame();
    try h.expectText("Chapter 1  /  Downloading 3/12");
    item.status = .queued;
    model.screen = .chapters;
    try h.frame();
    try h.expectText("Unread · Download paused 3/12 · Tap to resume");
}
