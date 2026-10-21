const std = @import("std");
const f = @import("fabrum");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @import("ui.zig");
const Harness = f.app.testing.Harness(.{}, Root);

test "library sort controls cycle requested modes and persist both directions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: tachi.Engine = .init(a, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{});
    var model: lib.Model = .{ .gpa = a };
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io };
    session.browser.engine = &engine;
    defer session.deinit();
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try session.loadSettings();
    try h.frame();
    const modes: []const tachi.views.SortMode = &.{ .alphabetical, .last_read, .date_added, .unread_count, .total_chapters, .latest_chapter };
    for (modes, 0..) |mode, i| {
        try std.testing.expectEqual(mode, session.currentSort().mode);
        const ascending = session.currentSort().ascending;
        try h.clickElement(h.root().element("library-sort-direction"));
        try std.testing.expectEqual(!ascending, session.currentSort().ascending);
        try h.clickElement(h.root().element("library-sort-direction"));
        try std.testing.expectEqual(ascending, session.currentSort().ascending);
        try h.clickElement(h.root().element("library-sort"));
        try std.testing.expectEqual(modes[(i + 1) % modes.len], session.currentSort().mode);
    }
}
