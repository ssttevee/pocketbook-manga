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
    .{ .id = "demo-1", .title = "The Copper Lantern", .cover = "demo/lantern.png", .author = "Sample library", .chapters = &.{
        .{ .id = "demo-1/1", .title = "Chapter 1 - A new beginning", .pages = &.{ "demo/001.png", "demo/002.png", "demo/003.png" } },
        .{ .id = "demo-1/2", .title = "Chapter 2 - The long road", .pages = &.{"demo/004.png"} },
    } },
    .{ .id = "demo-2", .title = "A Traveller's Notebook", .cover = "demo/notebook.png", .author = "Sample library" },
    .{ .id = "demo-3", .title = "Stories from the Observatory", .cover = "demo/observatory.png", .author = "Sample library" },
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
/// Synthetic grayscale artwork for previewing covers without copyrighted art.
pub fn sampleCover(session: *Session, path: []const u8, width: usize, height: usize) !@import("reader-image") {
    const pixels = try session.model.gpa.alloc(u8, width * height);
    const seed = std.hash.Wyhash.hash(0, path);
    for (0..height) |y| for (0..width) |x| {
        const frame = x < 3 or y < 3 or x + 3 >= width or y + 3 >= height;
        const horizon = y > height * 2 / 3;
        const stripe = (x + y / 2 + seed % 41) % 43 < 3;
        const window = x > width / 3 and x < width * 2 / 3 and y > height / 4 and y < height * 3 / 5;
        pixels[y * width + x] = if (frame) 45 else if (window) 245 else if (stripe) 95 else if (horizon) 80 else @intCast(160 + seed % 60);
    };
    return .{ .width = width, .height = height, .pixels = pixels, .revision = seed };
}
pub fn start(gpa: std.mem.Allocator, io: std.Io, session: *Session) !void {
    try fake.init(gpa, .{});
    errdefer fake.deinit();
    try Host.run(gpa, io, fake.api(), .{}, .{
        .fonts = &.{.{ .name = "Go", .data = @embedFile("fonts/Go-Regular.ttf") }},
        .provide = &.{f.app.RootValue.of(session)},
        .clock = fake.clock,
        // Press feedback must never trigger a periodic full-screen clean.
        // Reader page turns request their own full refreshes in ui.zig.
        .refresh = .{ .full_every = 0, .interactive = .dynamic },
        .context = .{ .units = 512, .breadth = 64 },
    });
    fake.advance(1);
}
pub fn stop() void {
    Host.instance.deinit();
    fake.deinit();
}
pub fn textPoint(value: []const u8) !struct { x: c_int, y: c_int } {
    const unit = f.app.testing.findText(Host.Runtime.Text, Host.instance.runtime.context(), value) orelse return error.TextNotFound;
    const center = f.app.testing.center(unit);
    const scale = Host.instance.screen.scale;
    return .{ .x = @intFromFloat(center.x * scale), .y = @intFromFloat(center.y * scale) };
}
pub fn tapText(value: []const u8) !void {
    const point = try textPoint(value);
    fake.tap(point.x, point.y);
    fake.advance(1);
}
pub fn pressText(value: []const u8) !void {
    const point = try textPoint(value);
    _ = fake.send(.pointer_down, point.x, point.y);
    fake.advance(1);
}
pub fn cancelPress() void {
    _ = fake.send(.pointer_cancel, 0, 0);
    fake.advance(1);
}
pub fn expectRowFeedback(value: []const u8) !void {
    const point = try textPoint(value);
    const offset = @as(usize, @intCast(point.y * fake.state.canvas.scanline + 30));
    const normal = fake.state.framebuffer[offset];
    const before_press = fake.state.updates.items.len;
    try pressText(value);
    try std.testing.expect(fake.state.framebuffer[offset] < normal);
    try expectSmallPartial(before_press, point.y);
    const before_release = fake.state.updates.items.len;
    _ = fake.send(.pointer_up, 0, 0); // Release outside: clear without activation.
    fake.advance(1);
    try std.testing.expectEqual(normal, fake.state.framebuffer[offset]);
    try expectSmallPartial(before_release, point.y);
}
fn expectSmallPartial(since: usize, row_y: c_int) !void {
    const updates = fake.state.updates.items[since..];
    try std.testing.expect(updates.len > 0);
    for (updates) |update| {
        try std.testing.expectEqual(fake.Update.Kind.partial, update.kind);
        try std.testing.expect(update.h > 0 and update.h <= 100);
        try std.testing.expect(update.y <= row_y and update.y + update.h >= row_y);
        try std.testing.expect(update.w < fake.state.width);
    }
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
    try tapText("Search library");
    try std.testing.expectEqual(1, fake.state.keyboards.items.len);
    fake.keyboardResult("observatory");
    fake.advance(1);
    try std.testing.expectEqualStrings("observatory", model.query_text);
    try std.testing.expectEqual(1, model.titleCount());
    try tapText("Stories from the Observatory");
    try std.testing.expectEqual(2, model.manga);
}

test "title and chapter press feedback stays within the row and never flashes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = fixture, .prefs = .{ .library_grid = false } };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    try start(std.testing.allocator, std.testing.io, &session);
    defer stop();
    // More than the host's default cleaning interval: taps must still be partial.
    for (0..8) |_| try expectRowFeedback("The Copper Lantern");
    try tapText("The Copper Lantern");
    try expectRowFeedback("Chapter 1 - A new beginning");
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
    try std.testing.expect(session.browser.busy == null);
}

test "partial reader mode still cleans every twelve page turns" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = fixture };
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io, .load_image = sampleImage };
    try start(std.testing.allocator, std.testing.io, &session);
    defer stop();
    try tapText("The Copper Lantern");
    try tapText("Chapter 1 - A new beginning");
    model.prefs.full_refresh = false;
    for (0..12) |i| {
        _ = fake.pressKey(if (i % 2 == 0) .next else .prev);
        try std.testing.expectEqual(if (i == 11) fake.Update.Kind.full else fake.Update.Kind.partial, fake.state.updates.items[fake.state.updates.items.len - 1].kind);
    }
}

test "native region pixels bypass resampling at panel scale with damage and padded rows" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture };
    defer model.deinit();
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    defer session.deinit();
    try start(std.testing.allocator, std.testing.io, &session);
    defer stop();
    const host = &Host.instance;
    const panel = fake.state.canvas;
    const width: usize = @intCast(panel.width);
    const height: usize = @intCast(panel.height);
    const stride: usize = @intCast(panel.scanline);
    try std.testing.expect(stride > width);
    const scale = host.screen.scale;
    try std.testing.expect(scale != 1);
    var pixels: [17 * 13]u8 = undefined;
    for (&pixels, 0..) |*pixel, i| pixel.* = @intCast((i * 37 + i / 17 * 11) % 251);
    var image: @import("reader-image") = .{
        .width = 17,
        .height = 13,
        .pixels = &pixels,
        .revision = 1,
        .native_scale = scale,
    };
    // Fractional point positions round to physical (13, 7). Resampling by
    // bbox edges would trim the first row/column and change this pattern.
    const commands: [1]f.layout.RenderCommand = .{.{
        .bbox = .init(13.2 / scale, 7.2 / scale, 17 / scale, 13 / scale),
        .data = .{ .content = &image.content },
    }};
    const target = try std.testing.allocator.alloc(u8, stride * height);
    defer std.testing.allocator.free(target);
    const surface: f.layout.Surface = .{ .pixels = .{
        .data = target,
        .width = @intCast(width),
        .height = @intCast(height),
        .stride = @intCast(stride),
        .format = .gray8,
        .scale = scale,
    } };
    const damage: [1]f.Rect = .{.init(18.25 / scale, 10.25 / scale, 5.5 / scale, 3.5 / scale)};
    for ([_]bool{ false, true }) |partial| {
        @memset(target, 0xA5);
        try host.renderer.render(&commands, surface, if (partial) &damage else null);
        for (0..height) |y| for (0..stride) |x| {
            const covered = x >= 13 and x < 30 and y >= 7 and y < 20;
            const damaged = !partial or (x >= 18 and x < 24 and y >= 10 and y < 14);
            const expected: u8 = if (covered and damaged) pixels[(y - 7) * 17 + x - 13] else if (x < width and damaged) 255 else 0xA5;
            try std.testing.expectEqual(expected, target[y * stride + x]);
        };
    }
}

test "image content respects later controls and scissor clipping on full and damaged redraws" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture };
    defer model.deinit();
    var session: Session = .{ .model = &model, .root = ".", .io = std.testing.io };
    defer session.deinit();
    try start(std.testing.allocator, std.testing.io, &session);
    defer stop();
    var source: [100]u8 = @splat(30);
    var image: @import("reader-image") = .{ .width = 10, .height = 10, .pixels = &source, .revision = 1 };
    const commands: [5]f.layout.RenderCommand = .{
        .{ .bbox = .init(2, 2, 6, 6), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = true } } },
        .{ .bbox = .init(0, 0, 10, 10), .data = .{ .content = &image.content } },
        .{ .bbox = .init(0, 0, 0, 0), .data = .scissor_end },
        .{ .bbox = .init(0, 0, 10, 3), .data = .{ .rectangle = .{ .color = .white, .corner_radius = .{} } } },
        .{ .bbox = .init(0, 7, 10, 3), .data = .{ .rectangle = .{ .color = .black, .corner_radius = .{} } } },
    };
    var target: [100]u8 = undefined;
    const surface: f.layout.Surface = .{ .pixels = .{ .data = &target, .width = 10, .height = 10, .stride = 10, .format = .gray8, .scale = 1 } };
    const damage: [1]f.Rect = .{.init(1, 1, 8, 8)};
    for ([_]bool{ false, true }) |partial| {
        @memset(&target, 165);
        try Host.instance.renderer.render(&commands, surface, if (partial) &damage else null);
        for (0..10) |y| for (0..10) |x| {
            const changed = !partial or (x >= 1 and x < 9 and y >= 1 and y < 9);
            const expected: u8 = if (!changed) 165 else if (y >= 7) 0 else if (y >= 3 and x >= 2 and x < 8) 30 else 255;
            try std.testing.expectEqual(expected, target[y * 10 + x]);
        };
    }
}
