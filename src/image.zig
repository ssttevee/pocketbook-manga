const std = @import("std");
const f = @import("fabrum");
const Image = @This();
content: f.layout.Content = .{ .vtable = &vtable },
width: usize,
height: usize,
pixels: []const u8,
revision: u64,
/// Region frames already match physical pixels; never fit or resample again.
native_scale: ?f32 = null,
const vtable: f.layout.Content.VTable = .{ .measure = measure, .fingerprint = fingerprint, .debug_name = "Manga page" };
fn measure(c: *f.layout.Content, limits: f.layout.Constraints) f.layout.Content.MeasureError!f.Vec2 {
    const self: *Image = @alignCast(@fieldParentPtr("content", c));
    const w: f32 = @floatFromInt(self.width);
    const h: f32 = @floatFromInt(self.height);
    if (self.native_scale) |scale| return .init(w / scale, h / scale);
    const scale = @min((limits.max_width orelse w) / w, (limits.max_height orelse h) / h);
    return .init(w * scale, h * scale);
}
fn fingerprint(c: *const f.layout.Content) u64 {
    const self: *const Image = @alignCast(@fieldParentPtr("content", c));
    return self.revision;
}
pub fn from(c: *f.layout.Content) ?*Image {
    if (c.vtable != &vtable) return null;
    return @alignCast(@fieldParentPtr("content", c));
}
