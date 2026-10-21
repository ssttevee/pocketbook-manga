const std = @import("std");
const f = @import("fabrum");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;

test "Browse tabs share the root navigation and seven source rows fit the device viewport" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var sources: [7]tachi.models.SourceInfo = undefined;
    for (&sources, 0..) |*source, i| source.* = .{
        .id = "42",
        .name = try std.fmt.allocPrint(arena.allocator(), "Source {d}", .{i + 1}),
        .lang = "en",
        .supportsLatest = true,
        .isConfigurable = false,
        .className = "Fixture",
        .extensionPkg = "fixture.extension",
    };
    var notes: [7][]const u8 = @splat("Last used · Pinned · A very long source note that must stay within the row");
    var model: lib.Model = .{ .gpa = arena.allocator(), .screen = .sources };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = "." };
    session.browser.source_rows = &sources;
    session.browser.source_notes = &notes;
    defer session.deinit();
    session.setStatus("Sources updated");
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    const last_row = h.findText("Source 7").?;
    const next = h.findText("Next").?;
    const bar = h.findElement(h.root().element("bottom-navigation")).?;
    try std.testing.expect(last_row.bbox.y + last_row.bbox.h <= next.bbox.y);
    try std.testing.expect(next.bbox.y + next.bbox.h <= bar.bbox.y);
    try std.testing.expect(bar.bbox.y + bar.bbox.h <= 464);
    try h.click("Extensions");
    try std.testing.expectEqual(lib.Screen.extensions, model.screen);
    try h.expectNoText("Back");
    try std.testing.expect(h.findElement(h.root().element("bottom-navigation")) != null);
    try session.browser.setQuery(arena.allocator(), "keep filter");
    session.browser.offset = 3;
    session.setStatus("Kept extensions snapshot");
    try h.frame();
    try h.clickElement(h.root().element("browse"));
    try std.testing.expectEqual(lib.Screen.extensions, model.screen);
    try std.testing.expectEqual(3, session.browser.offset);
    try std.testing.expectEqualStrings("keep filter", session.browser.query);
    try std.testing.expectEqualStrings("Kept extensions snapshot", session.status);
    try h.click("Sources");
    try std.testing.expectEqual(lib.Screen.sources, model.screen);
    try std.testing.expectEqual(0, session.browser.offset);
    try h.expectText("Source 7");
    session.browser.offset = 3;
    session.setStatus("Kept sources snapshot");
    try h.frame();
    try h.clickElement(h.root().element("browse"));
    try std.testing.expectEqual(lib.Screen.sources, model.screen);
    try std.testing.expectEqual(3, session.browser.offset);
    try std.testing.expectEqualStrings("Kept sources snapshot", session.status);
}
