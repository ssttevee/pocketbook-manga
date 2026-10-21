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
