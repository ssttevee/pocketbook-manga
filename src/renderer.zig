//! Adds opaque grayscale page content to the platform's z2d UI renderer.
//! Images share command order and clipping with controls and text.
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
    var base = try Base.init(gpa);
    base.custom_content = paintImage;
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
}

fn paintImage(content: *f.layout.Content, box: f.Rect, pixels: f.layout.Surface.Pixels, origin: f.Vec2) !void {
    const image = Image.from(content) orelse return;
    const native = image.native_scale != null;
    const x0: i32 = @intFromFloat(if (native) @round(box.x) else @ceil(box.x));
    const y0: i32 = @intFromFloat(if (native) @round(box.y) else @ceil(box.y));
    const x1: i32 = if (native) x0 + @as(i32, @intCast(image.width)) else @intFromFloat(@floor(box.x + box.w));
    const y1: i32 = if (native) y0 + @as(i32, @intCast(image.height)) else @intFromFloat(@floor(box.y + box.h));
    const ox: i32 = @intFromFloat(origin.x);
    const oy: i32 = @intFromFloat(origin.y);
    const left = @max(x0, ox);
    const top = @max(y0, oy);
    const right = @min(x1, ox + @as(i32, @intCast(pixels.width)));
    const bottom = @min(y1, oy + @as(i32, @intCast(pixels.height)));
    if (right <= left or bottom <= top) return;
    for (@intCast(top)..@intCast(bottom)) |y| for (@intCast(left)..@intCast(right)) |x| {
        const dx: usize = @intCast(@as(i32, @intCast(x)) - x0);
        const dy: usize = @intCast(@as(i32, @intCast(y)) - y0);
        const sx = if (native) dx else @min(image.width - 1, dx * image.width / @as(usize, @intCast(x1 - x0)));
        const sy = if (native) dy else @min(image.height - 1, dy * image.height / @as(usize, @intCast(y1 - y0)));
        const gray = image.pixels[sy * image.width + sx];
        const offset = @as(usize, @intCast(@as(i32, @intCast(y)) - oy)) * pixels.stride + @as(usize, @intCast(@as(i32, @intCast(x)) - ox)) * 4;
        pixels.data[offset..][0..4].* = .{ gray, gray, gray, 255 };
    };
}
