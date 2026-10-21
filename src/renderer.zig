//! Adds opaque grayscale page content to the platform's z2d UI renderer.
//! Pages live in their own non-scrolling, non-overlapping viewport.
const std = @import("std");
const f = @import("fabrum");
const Base = @import("base");
const Image = @import("reader-image");
const Self = @This();
base: Base,
text_context: Text.Context,
pub const Text = Base.Text;
pub const surfaces = Base.surfaces;
pub fn init(gpa: std.mem.Allocator) !Self {
    const base = try Base.init(gpa);
    return .{ .base = base, .text_context = base.text_context };
}
pub fn deinit(self: *Self) void {
    self.base.deinit();
}
pub fn loadFont(self: *Self, name: [:0]const u8, data: []const u8) !void {
    try self.base.loadFont(name, data);
}
pub fn render(self: *Self, commands: []const f.layout.RenderCommand, surface: f.layout.Surface, damage: ?[]const f.Rect) !void {
    try self.base.render(commands, surface, damage);
    const pixels = surface.pixels;
    if (pixels.format != .gray8) return error.UnsupportedSurface;
    const size = pixels.pointSize();
    const whole: [1]f.Rect = .{.init(0, 0, size.x, size.y)};
    for (commands) |cmd| {
        if (cmd.data != .content) continue;
        const image = Image.from(cmd.data.content) orelse continue;
        const b = cmd.bbox;
        const native = image.native_scale != null;
        const x0: usize = @intFromFloat(@max(0, if (native) @round(b.x * pixels.scale) else @ceil(b.x * pixels.scale)));
        const y0: usize = @intFromFloat(@max(0, if (native) @round(b.y * pixels.scale) else @ceil(b.y * pixels.scale)));
        const x1: usize = if (native) @min(pixels.width, x0 + image.width) else @intFromFloat(@min(@as(f32, @floatFromInt(pixels.width)), @floor((b.x + b.w) * pixels.scale)));
        const y1: usize = if (native) @min(pixels.height, y0 + image.height) else @intFromFloat(@min(@as(f32, @floatFromInt(pixels.height)), @floor((b.y + b.h) * pixels.scale)));
        if (x1 <= x0 or y1 <= y0) continue;
        for (damage orelse &whole) |r| {
            const left = @max(x0, @as(usize, @intFromFloat(@max(0, @floor(r.x * pixels.scale)))));
            const top = @max(y0, @as(usize, @intFromFloat(@max(0, @floor(r.y * pixels.scale)))));
            const right = @min(x1, @as(usize, @intFromFloat(@max(0, @ceil((r.x + r.w) * pixels.scale)))));
            const bottom = @min(y1, @as(usize, @intFromFloat(@max(0, @ceil((r.y + r.h) * pixels.scale)))));
            if (right <= left or bottom <= top) continue;
            for (top..bottom) |y| for (left..right) |x| {
                const source_x = if (native) x - x0 else @min(image.width - 1, (x - x0) * image.width / (x1 - x0));
                const source_y = if (native) y - y0 else @min(image.height - 1, (y - y0) * image.height / (y1 - y0));
                pixels.data[y * pixels.stride + x] = image.pixels[source_y * image.width + source_x];
            };
        }
    }
}
