//! Pixel geometry for width-fitted webtoons and height-fitted wide pages.
//! Progress follows reading order, so horizontal RTL starts at the right edge.
const std = @import("std");

pub const Size = struct { width: u32, height: u32 };
pub const Rect = struct { x: u32, y: u32, width: u32, height: u32 };
pub const Axis = enum { page, vertical, horizontal };
pub const Geometry = struct {
    source: Size,
    viewport: Size,
    output: Size,
    axis: Axis,
    rtl: bool,

    pub fn init(source: Size, viewport: Size, rtl: bool) Geometry {
        const src: Size = .{ .width = @max(1, source.width), .height = @max(1, source.height) };
        const view: Size = .{ .width = @max(1, viewport.width), .height = @max(1, viewport.height) };
        const width_scale = @as(f64, @floatFromInt(view.width)) / @as(f64, @floatFromInt(src.width));
        const height_scale = @as(f64, @floatFromInt(view.height)) / @as(f64, @floatFromInt(src.height));
        const axis: Axis = if (width_scale > height_scale * 1.25) .vertical else if (height_scale > width_scale * 1.25) .horizontal else .page;
        const scale = switch (axis) {
            .vertical => width_scale,
            .horizontal => height_scale,
            .page => @min(width_scale, height_scale),
        };
        return .{ .source = src, .viewport = view, .output = .{ .width = scaled(src.width, scale), .height = scaled(src.height, scale) }, .axis = axis, .rtl = rtl };
    }

    fn scaled(value: u32, scale: f64) u32 {
        return @intFromFloat(@max(1, @min(@as(f64, @floatFromInt(std.math.maxInt(u32))), @round(@as(f64, @floatFromInt(value)) * scale))));
    }

    pub fn region(self: Geometry, progress: f64) Rect {
        const p = clamp(progress);
        const x_max = self.output.width -| self.viewport.width;
        const y_max = self.output.height -| self.viewport.height;
        return .{
            .x = @intFromFloat(@round(@as(f64, @floatFromInt(x_max)) * if (self.rtl) 1 - p else p)),
            .y = @intFromFloat(@round(@as(f64, @floatFromInt(y_max)) * p)),
            .width = @min(self.output.width, self.viewport.width),
            .height = @min(self.output.height, self.viewport.height),
        };
    }

    /// A screenful with 10% overlap, clamped to the final source edge.
    /// Returns null only when a turn should move to another source image.
    pub fn step(self: Geometry, progress: f64, delta: i32) ?f64 {
        const p = clamp(progress);
        if (delta == 0) return p;
        const extent = switch (self.axis) {
            .page => return null,
            .vertical => self.output.height -| self.viewport.height,
            .horizontal => self.output.width -| self.viewport.width,
        };
        if (extent == 0 or (delta > 0 and p >= 1) or (delta < 0 and p <= 0)) return null;
        const visible = switch (self.axis) {
            .page => unreachable,
            .vertical => self.viewport.height,
            .horizontal => self.viewport.width,
        };
        return clamp(p + @as(f64, @floatFromInt(delta)) * @as(f64, @floatFromInt(visible)) * 0.9 / @as(f64, @floatFromInt(extent)));
    }

    pub fn atEnd(self: Geometry, progress: f64) bool {
        return self.axis == .page or clamp(progress) >= 1;
    }
};

pub fn clamp(progress: f64) f64 {
    return if (std.math.isFinite(progress)) std.math.clamp(progress, 0, 1) else 0;
}

test "vertical webtoons retain overlap and stop exactly at the bottom" {
    const g = Geometry.init(.{ .width = 2000, .height = 30000 }, .{ .width = 758, .height = 900 }, true);
    try std.testing.expectEqual(Axis.vertical, g.axis);
    try std.testing.expectEqual(@as(u32, 11370), g.output.height);
    var progress: f64 = 0;
    try std.testing.expect(!g.atEnd(progress));
    while (g.step(progress, 1)) |next| progress = next;
    try std.testing.expect(g.atEnd(progress));
    try std.testing.expectEqual(g.output.height - g.viewport.height, g.region(progress).y);
    try std.testing.expectEqual(@as(u32, 0), g.region(0).y);
    try std.testing.expect(g.step(progress, -1).? < 1);
}

test "wide pages pan in reading order for both directions" {
    for ([_]bool{ false, true }) |rtl| {
        const g = Geometry.init(.{ .width = 12000, .height = 1000 }, .{ .width = 758, .height = 900 }, rtl);
        try std.testing.expectEqual(Axis.horizontal, g.axis);
        const start = g.region(0);
        const next = g.region(g.step(0, 1).?);
        if (rtl) {
            try std.testing.expect(start.x > next.x);
            try std.testing.expectEqual(@as(u32, 0), g.region(1).x);
        } else {
            try std.testing.expect(start.x < next.x);
            try std.testing.expectEqual(@as(u32, 0), start.x);
        }
        try std.testing.expectEqual(@as(u32, 0), start.y);
        try std.testing.expectEqual(@as(?f64, null), g.step(1, 1));
    }
}

test "ordinary pages fit completely and normalized position survives resizing" {
    const page = Geometry.init(.{ .width = 700, .height = 1000 }, .{ .width = 758, .height = 1000 }, true);
    try std.testing.expectEqual(Axis.page, page.axis);
    try std.testing.expect(page.atEnd(0));
    try std.testing.expectEqual(@as(?f64, null), page.step(0, 1));
    const tall = Geometry.init(.{ .width = 1000, .height = 10000 }, .{ .width = 758, .height = 900 }, false);
    const resized = Geometry.init(tall.source, .{ .width = 600, .height = 700 }, false);
    try std.testing.expectEqual((resized.output.height - resized.viewport.height) / 2, resized.region(0.5).y);
    try std.testing.expectEqual(tall.region(0), tall.region(std.math.nan(f64)));
    try std.testing.expectEqual(tall.region(1), tall.region(42));
    try std.testing.expectEqual(@as(u32, 1), Geometry.init(.{ .width = 0, .height = 0 }, .{ .width = 0, .height = 0 }, false).output.width);
}
