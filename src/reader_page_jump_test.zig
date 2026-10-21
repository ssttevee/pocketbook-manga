const std = @import("std");
const f = @import("fabrum");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @import("ui.zig");
const fixture: lib.Library = .{ .manga = &.{.{ .id = "m", .title = "Story", .chapters = &.{.{ .id = "c", .title = "C", .pages = &.{ "1.png", "2.png", "3.png" } }} }} };

test "reader progress jumps to absolute pages and validates numeric input" {
    for ([_]lib.viewport.Size{ .{ .width = 300, .height = 3000 }, .{ .width = 3000, .height = 300 } }) |source| for ([_]bool{ false, true }) |rtl| {
        var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_requires_presentation = true, .prefs = .{ .rtl = rtl } };
        defer model.deinit();
        try model.dispatch(.{ .read = 0 });
        model.reader_geometry = lib.viewport.Geometry.init(source, .{ .width = 300, .height = 400 }, rtl);
        model.reader_position = 0.75;
        var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
        defer session.deinit();
        var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
        defer h.deinit();
        try h.frame();
        try h.expectText(fixture.manga[0].title);
        try h.expectText(fixture.manga[0].chapters[0].title);
        try h.clickAt(.init(170, 12));
        try h.clickElement(h.root().element("reader-progress"));
        try h.enterText("3");
        try std.testing.expectEqual(2, model.page);
        try std.testing.expectEqual(@as(f64, 0), model.reader_position);
        try std.testing.expect(model.reader_geometry == null);
        try std.testing.expect(!model.reader_presented);
        try std.testing.expect(!model.readState(fixture.manga[0].chapters[0]).read);
        try h.clickElement(h.root().element("reader-progress"));
        try h.enterText("1");
        try std.testing.expectEqual(0, model.page);
        try std.testing.expectError(error.PageOutOfRange, model.dispatch(.{ .jump_page = 3 }));
        try h.clickElement(h.root().element("reader-progress"));
        try h.enterText("0");
        try std.testing.expectEqual(0, model.page);
        try std.testing.expectEqualStrings("Enter a page from 1 to 3.", h.tree.dialogs.items[0].text);
    };
}
