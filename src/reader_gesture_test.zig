const std = @import("std");
const f = @import("fabrum");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;
const fixture: lib.Library = .{ .manga = &.{.{ .id = "m", .title = "M", .chapters = &.{.{ .id = "c", .title = "C", .pages = &.{"1.png"} }} }} };

test "reader releases a vertical drag before moving and hides chapter skip until the bottom" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    model.reader_zoom = true;
    try model.configureReader(.{ .width = 1000, .height = 12000 }, .{ .width = 686, .height = 760 });
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io, .next_chapter = 0 };
    defer session.deinit();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.expectNoText("Chapter >");
    try h.drag(.init(170, 300), .init(170, 120), 3);
    try std.testing.expect(model.reader_position > 0);
    try std.testing.expect(!model.readState(fixture.manga[0].chapters[0]).read);
    try session.act(.{ .pan = 1 });
    try h.frame();
    try h.clickAt(.init(170, 12));
    try h.expectText("Chapter >");
    try std.testing.expect(model.readState(fixture.manga[0].chapters[0]).read);
}

test "wide reader drags reverse correctly for horizontal RTL and LTR" {
    for ([_]bool{ false, true }) |rtl| {
        var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .prefs = .{ .rtl = rtl } };
        defer model.deinit();
        try model.dispatch(.{ .read = 0 });
        model.reader_zoom = true;
        try model.configureReader(.{ .width = 12000, .height = 1000 }, .{ .width = 686, .height = 760 });
        var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
        defer session.deinit();
        var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
        defer h.deinit();
        try h.frame();
        try h.drag(.init(if (rtl) 80 else 260, 200), .init(if (rtl) 260 else 80, 200), 3);
        try std.testing.expect(model.reader_position > 0);
        try std.testing.expectEqual(@as(usize, 0), model.page);
    }
}

test "reader starts fullscreen and edge taps toggle chrome without turning or resizing" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    defer session.deinit();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    const page = h.root().element("page");
    const initial = h.findElement(page).?.bbox;
    try std.testing.expectEqual(@as(f32, 0), initial.y);
    try std.testing.expectEqual(@as(f32, 464), initial.h);
    try h.expectNoText("Back");
    try h.expectNoText("Next");
    try h.clickAt(.init(170, 12));
    try h.expectText("Back");
    try h.expectText("Next");
    try std.testing.expectEqual(initial, h.findElement(page).?.bbox);
    try std.testing.expectEqual(@as(usize, 0), model.page);
    // A page tap dismisses the controls without also advancing.
    try h.clickAt(.init(20, 230));
    try h.expectNoText("Back");
    try h.clickAt(.init(170, 450));
    try h.expectText("Back");
    try h.click("Back");
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    try session.act(.{ .read = 0 });
    try h.frame();
    try h.expectNoText("Back");
}
