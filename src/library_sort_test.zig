const std = @import("std");
const f = @import("fabrum");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @import("ui.zig");
const Harness = f.app.testing.Harness(.{}, Root);

test "library sort menu selects arbitrary modes and persists both directions" {
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
    const sort_button = h.findElement(h.root().element("library-sort")).?.bbox;
    try std.testing.expect(sort_button.h >= 34);
    try std.testing.expect(h.findElement(h.root().element("library-sort-direction")).?.bbox.w >= 52);
    for ([_]usize{ 5, 2, 4, 1, 3, 0 }) |i| {
        const before = session.currentSort().mode;
        const ascending = session.currentSort().ascending;
        try h.clickElement(h.root().element("library-sort"));
        try std.testing.expectEqual(before, session.currentSort().mode);
        try h.chooseMenuItem(i);
        try std.testing.expectEqual(modes[i], session.currentSort().mode);
        try std.testing.expectEqual(ascending, session.currentSort().ascending);
        try h.clickElement(h.root().element("library-sort-direction"));
        try std.testing.expectEqual(!ascending, session.currentSort().ascending);
        try h.clickElement(h.root().element("library-sort-direction"));
        try std.testing.expectEqual(ascending, session.currentSort().ascending);
    }
    try h.clickElement(h.root().element("library-sort"));
    try h.chooseMenuItem(null);
    try std.testing.expectEqual(.alphabetical, session.currentSort().mode);
}

test "library list titles use one line and grid menu is a visible touch button" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const title = "A very long manga title that must remain one line in the list despite having far more words than can fit";
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = .{ .manga = &.{.{ .id = "s", .title = title }} } };
    model.prefs.library_grid = false;
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    defer session.deinit();
    var h: Harness = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try std.testing.expect(h.findText(title).?.bbox.h <= 15);
    try h.clickElement(h.root().element("library-layout"));
    const dots = h.findText("...").?;
    const menu_unit = h.runtime.context().units.items[dots.parent];
    const menu_id: f.layout.Unit.Id = .fromInt(menu_unit.id);
    const menu = menu_unit.bbox;
    try std.testing.expect(menu.w >= 40 and menu.h >= 32);
    const nav = h.findElement(h.root().element("bottom-navigation")).?.bbox;
    try std.testing.expect(menu.y + menu.h <= nav.y);
    const card_footer = h.runtime.context().units.items[menu_unit.parent].bbox;
    try std.testing.expectEqual(@as(f32, 148), card_footer.w);
    try std.testing.expectEqual(@as(u8, 245), h.findElement(menu_id).?.data.container.background_color.r);
    const point: f.Vec2 = .init(menu.x + menu.w / 2, menu.y + menu.h / 2);
    var buttons: f.app.MouseEvent.Buttons = .empty;
    buttons.set(f.app.MouseEvent.primary);
    _ = try h.mouse(.{ .position = point, .pressed = buttons });
    try std.testing.expectEqual(@as(u8, 190), h.findElement(menu_id).?.data.container.background_color.r);
    _ = try h.mouse(.{ .position = point });
    try std.testing.expectEqual(.title_menu, model.screen);
}
