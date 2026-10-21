const std = @import("std");
const f = @import("fabrum");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;

test "Mihon root destinations stay in the bottom navigation and More returns from its tools" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var model: lib.Model = .{ .gpa = arena.allocator() };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    defer session.deinit();
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    const bar = h.findElement(h.root().element("bottom-navigation")).?;
    try std.testing.expectEqual(@as(f32, 58), bar.bbox.h);
    try std.testing.expect(bar.bbox.y + bar.bbox.h <= 464);
    try h.expectNoText("Back");
    try h.clickElement(h.root().element("updates"));
    try std.testing.expectEqual(lib.Screen.updates, model.screen);
    try h.expectNoText("Back");
    try h.clickElement(h.root().element("history"));
    try std.testing.expectEqual(lib.Screen.history, model.screen);
    try h.clickElement(h.root().element("more"));
    try std.testing.expectEqual(lib.Screen.settings, model.screen);
    try h.expectText("Download queue");
    try h.expectNoText("Back");
    const close = h.findText("Close PocketManga").?;
    const more_bar = h.findElement(h.root().element("bottom-navigation")).?;
    try std.testing.expect(close.bbox.y + close.bbox.h <= more_bar.bbox.y);
    try std.testing.expectEqual(@as(f32, 58), more_bar.bbox.h);
    try std.testing.expect(more_bar.bbox.y + more_bar.bbox.h <= 464);
    const reference = h.findElement(h.root().element("library")).?.bbox;
    inline for (.{ "updates", "history", "browse", "more" }) |name| {
        const tab = h.findElement(h.root().element(name)).?.bbox;
        try std.testing.expectApproxEqAbs(reference.w, tab.w, 0.01);
        try std.testing.expectEqual(reference.h, tab.h);
    }
    try h.click("Reading settings");
    try h.expectText("Right to left (manga)");
    try std.testing.expect(h.findElement(h.root().element("bottom-navigation")) == null);
    try h.click("Back");
    try h.expectText("Reading settings");
    try h.click("Download queue");
    try std.testing.expectEqual(lib.Screen.queue, model.screen);
    try h.click("Back");
    try h.expectText("Download queue");
    try h.clickElement(h.root().element("library"));
    try std.testing.expectEqual(lib.Screen.library, model.screen);
}
