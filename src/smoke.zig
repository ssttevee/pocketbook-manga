//! The actual application hosted by the platform's fake InkView panel.
const std = @import("std");
const f = @import("fabrum");
const ink = @import("fabrum-platform-inkview");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;
pub const Host = ink.App(Root);
pub const fake = ink.fake;
pub const fixture: lib.Library = .{ .manga = &.{
    .{ .id = "demo-1", .title = "The Copper Lantern", .author = "Sample library", .chapters = &.{
        .{ .id = "demo-1/1", .title = "Chapter 1 - A new beginning", .pages = &.{ "demo/001.png", "demo/002.png", "demo/003.png" } },
        .{ .id = "demo-1/2", .title = "Chapter 2 - The long road", .pages = &.{"demo/004.png"} },
    } },
    .{ .id = "demo-2", .title = "A Traveller's Notebook", .author = "Sample library" },
    .{ .id = "demo-3", .title = "Stories from the Observatory", .author = "Sample library" },
} };
pub fn sampleImage(session: *Session, path: []const u8) !void {
    const width = 240;
    const height = 340;
    const pixels = try session.model.gpa.alloc(u8, width * height);
    const shade: u8 = if (std.mem.endsWith(u8, path, "002.png")) 70 else 180;
    // A deliberately synthetic page, to inspect geometry and grayscale.
    for (0..height) |y| for (0..width) |x| {
        const border = x < 6 or y < 6 or x >= width - 6 or y >= height - 6;
        const gutter = (y > 160 and y < 174) or (x > 112 and x < 124 and y > 174);
        const band = (x + y) % 70 < 8;
        pixels[y * width + x] = if (border) 0 else if (gutter) 255 else if (band) 30 else shade;
    };
    if (session.image) |old| session.model.gpa.free(old.pixels);
    session.image = .{ .width = width, .height = height, .pixels = pixels, .revision = std.hash.Wyhash.hash(0, path) };
}
pub fn start(gpa: std.mem.Allocator, io: std.Io, session: *Session) !void {
    try fake.init(gpa, .{});
    errdefer fake.deinit();
    try Host.run(gpa, io, fake.api(), .{}, .{
        .fonts = &.{.{ .name = "Go", .data = @embedFile("fonts/Go-Regular.ttf") }},
        .provide = &.{f.app.RootValue.of(session)},
        .clock = fake.clock,
        .context = .{ .units = 512, .breadth = 64 },
    });
    fake.advance(1);
}
pub fn stop() void {
    Host.instance.deinit();
    fake.deinit();
}
pub fn tapText(value: []const u8) !void {
    const unit = f.app.testing.findText(Host.Runtime.Text, Host.instance.runtime.context(), value) orelse return error.TextNotFound;
    const center = f.app.testing.center(unit);
    const scale = Host.instance.screen.scale;
    fake.tap(@intFromFloat(center.x * scale), @intFromFloat(center.y * scale));
    fake.advance(1);
}
pub fn writeScreen(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const width: usize = @intCast(fake.state.width);
    const height: usize = @intCast(fake.state.height);
    const stride: usize = @intCast(fake.state.canvas.scanline);
    const header = try std.fmt.allocPrint(gpa, "P5\n{d} {d}\n255\n", .{ width, height });
    defer gpa.free(header);
    const file = try gpa.alloc(u8, header.len + width * height);
    defer gpa.free(file);
    @memcpy(file[0..header.len], header);
    for (0..height) |y| @memcpy(file[header.len + y * width ..][0..width], fake.state.framebuffer[y * stride ..][0..width]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file });
}
test "InkView page keys, tap direction, refresh hints and damage match a full redraw" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = fixture };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io, .load_image = sampleImage };
    try start(std.testing.allocator, std.testing.io, &session);
    defer stop();
    try tapText("The Copper Lantern");
    try tapText("Chapter 1 - A new beginning");
    try std.testing.expectEqual(lib.Screen.reader, model.screen);
    _ = fake.pressKey(.next);
    try std.testing.expectEqual(1, model.page);
    try std.testing.expectEqual(fake.Update.Kind.full, fake.state.updates.items[fake.state.updates.items.len - 1].kind);
    fake.tap(40, 500); // The left half advances manga in RTL mode.
    try std.testing.expectEqual(2, model.page);
    _ = fake.pressKey(.prev);
    try std.testing.expectEqual(1, model.page);
    model.prefs.full_refresh = false;
    _ = fake.pressKey(.prev);
    try std.testing.expectEqual(0, model.page);
    const host = &Host.instance;
    const panel = fake.state.canvas;
    const full = try std.testing.allocator.alloc(u8, fake.state.framebuffer.len);
    defer std.testing.allocator.free(full);
    @memset(full, 255);
    try host.renderer.render(host.runtime.commands(), .{ .pixels = .{
        .data = full,
        .width = @intCast(panel.width),
        .height = @intCast(panel.height),
        .stride = @intCast(panel.scanline),
        .format = .gray8,
        .scale = host.screen.scale,
    } }, null);
    for (0..@intCast(panel.height)) |y| {
        const offset = y * @as(usize, @intCast(panel.scanline));
        try std.testing.expectEqualSlices(u8, full[offset..][0..@intCast(panel.width)], fake.state.framebuffer[offset..][0..@intCast(panel.width)]);
    }
    _ = fake.pressKey(.back);
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    _ = fake.pressKey(.back);
    try std.testing.expectEqual(lib.Screen.library, model.screen);
    _ = fake.pressKey(.back);
    try std.testing.expect(fake.state.closed);
}

test "InkView system keyboard filters the library by title" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = fixture };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    try start(std.testing.allocator, std.testing.io, &session);
    defer stop();
    try tapText("Search title or author");
    try std.testing.expectEqual(1, fake.state.keyboards.items.len);
    fake.keyboardResult("observatory");
    fake.advance(1);
    try std.testing.expectEqualStrings("observatory", model.query_text);
    try std.testing.expectEqual(1, model.titleCount());
    try tapText("Stories from the Observatory");
    try std.testing.expectEqual(2, model.manga);
}
