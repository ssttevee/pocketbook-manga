//! A bounded, display-resolution window over consecutive width-fitted images.
const std = @import("std");
const cache = @import("region_cache.zig");
const vp = @import("reader_viewport.zig");

pub const Anchor = struct { page: usize, position: f64 = 0 };
pub const Resolver = struct {
    context: *anyopaque,
    path: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![:0]const u8,
};
pub const Context = struct { gpa: std.mem.Allocator, io: std.Io, tiles: *cache.Service, resolver: Resolver };
pub const Request = struct { pages: []const []const u8, anchor: Anchor, delta: f64 = 0, viewport: cache.Size };
pub const Output = struct { frame: cache.Frame, anchor: Anchor, at_end: bool, waiting: bool, last_visible_page: usize, content_height: u32 = 0 };
const max_images = 128;

pub fn render(ctx: Context, arena: std.mem.Allocator, request: Request, checkpoint: cache.Checkpoint) !Output {
    return (try compose(ctx, arena, request, checkpoint, false)).?;
}

/// Uses prepared metadata and immutable tiles only; never enters a decoder.
pub fn cached(ctx: Context, arena: std.mem.Allocator, request: Request) !?Output {
    return compose(ctx, arena, request, .{}, true);
}

const Walker = struct {
    ctx: Context,
    arena: std.mem.Allocator,
    request: Request,
    checkpoint: cache.Checkpoint,
    cached_only: bool,
    remaining: usize = max_images,

    fn path(self: *Walker, page: usize) ![:0]const u8 {
        try self.checkpoint.run(self.ctx.io);
        if (self.remaining == 0) return error.TooManyContinuousImages;
        self.remaining -= 1;
        if (self.request.pages[page].len == 0) return error.PageNotDownloaded;
        return self.ctx.resolver.path(self.ctx.resolver.context, self.arena, self.request.pages[page]);
    }
    fn geometry(self: *Walker, filename: [:0]const u8) !?vp.Geometry {
        if (try self.ctx.tiles.cachedVerticalGeometry(self.ctx.io, filename, self.request.viewport)) |value| return value;
        if (self.cached_only) return null;
        // A zero-height slice prepares only metadata, without decoding tiles.
        const frame = try self.ctx.tiles.verticalSlice(self.arena, self.ctx.io, filename, self.request.viewport, .{ .top = 0, .height = 0 }, self.checkpoint);
        self.arena.free(frame.pixels);
        return frame.geometry;
    }
};

fn compose(ctx: Context, arena: std.mem.Allocator, request: Request, checkpoint: cache.Checkpoint, cached_only: bool) !?Output {
    if (request.pages.len == 0 or request.anchor.page >= request.pages.len) return error.InvalidPage;
    if (request.viewport.width == 0 or request.viewport.height == 0 or request.viewport.width > 8192 or request.viewport.height > 8192) return error.InvalidViewport;
    var walk: Walker = .{ .ctx = ctx, .arena = arena, .request = request, .checkpoint = checkpoint, .cached_only = cached_only };
    var page = request.anchor.page;
    var path = try walk.path(page);
    var geometry = (try walk.geometry(path)) orelse return null;
    var top = vp.clamp(request.anchor.position) * @as(f64, @floatFromInt(geometry.output.height));
    top += if (std.math.isFinite(request.delta)) request.delta else 0;
    const original_geometry = geometry;
    const original_path = path;
    var blocked = false;
    while (top >= @as(f64, @floatFromInt(geometry.output.height)) and page + 1 < request.pages.len) {
        const next_path = walk.path(page + 1) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory, error.TooManyContinuousImages => return err,
            else => {
                blocked = true;
                break;
            },
        };
        const next_geometry = (walk.geometry(next_path) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory, error.TooManyContinuousImages => return err,
            else => {
                blocked = true;
                break;
            },
        }) orelse return null;
        top -= @floatFromInt(geometry.output.height);
        page += 1;
        path = next_path;
        geometry = next_geometry;
    }
    if (blocked) {
        page = request.anchor.page;
        path = original_path;
        geometry = original_geometry;
        top = vp.clamp(request.anchor.position) * @as(f64, @floatFromInt(geometry.output.height));
    }
    // Keep the final viewport filled, walking back over short footer strips.
    if (page + 1 == request.pages.len) top = @min(top, @as(f64, @floatFromInt(geometry.output.height)) - @as(f64, @floatFromInt(request.viewport.height)));
    while (top < 0 and page > 0) {
        if (request.pages[page - 1].len == 0) {
            top = 0;
            break;
        }
        page -= 1;
        path = try walk.path(page);
        geometry = (try walk.geometry(path)) orelse return null;
        top += @floatFromInt(geometry.output.height);
    }
    top = @max(0, top);
    const start_height = geometry.output.height;
    var offset: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(geometry.output.height - 1)), @round(top)));
    const anchor: Anchor = .{ .page = page, .position = @as(f64, @floatFromInt(offset)) / @as(f64, @floatFromInt(start_height)) };
    const pixels = try arena.alloc(u8, @as(usize, request.viewport.width) * request.viewport.height);
    var success = false;
    defer if (!success) arena.free(pixels);
    @memset(pixels, 255);
    var filled: u32 = 0;
    var last = page;
    var at_end = false;
    var revision = std.hash.Wyhash.init(0x434f4e54494e5545);
    while (filled < request.viewport.height) {
        try checkpoint.run(ctx.io);
        const rows = @min(request.viewport.height - filled, geometry.output.height - offset);
        const part = if (cached_only)
            (try ctx.tiles.cachedVerticalSlice(arena, ctx.io, path, request.viewport, .{ .top = offset, .height = rows })) orelse return null
        else
            ctx.tiles.verticalSlice(arena, ctx.io, path, request.viewport, .{ .top = offset, .height = rows }, checkpoint) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory => return err,
                else => {
                    if (filled == 0) return err;
                    std.log.debug("Continuous following image: {s}", .{@errorName(err)});
                    blocked = true;
                    break;
                },
            };
        defer arena.free(part.pixels);
        const left = (request.viewport.width - part.rect.width) / 2;
        for (0..part.rect.height) |row| {
            const destination = (@as(usize, filled) + row) * request.viewport.width + left;
            @memcpy(pixels[destination..][0..part.rect.width], part.pixels[row * part.rect.width ..][0..part.rect.width]);
        }
        revision.update(std.mem.asBytes(&part.revision));
        filled += part.rect.height;
        last = page;
        if (page + 1 == request.pages.len and offset + rows >= geometry.output.height) {
            at_end = true;
            break;
        }
        if (filled == request.viewport.height) break;
        if (request.pages[page + 1].len == 0) {
            blocked = true;
            break;
        }
        page += 1;
        path = walk.path(page) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory, error.TooManyContinuousImages => return err,
            else => {
                blocked = true;
                break;
            },
        };
        geometry = (walk.geometry(path) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory, error.TooManyContinuousImages => return err,
            else => {
                blocked = true;
                break;
            },
        }) orelse return null;
        offset = 0;
    }
    success = true;
    const frame_geometry: vp.Geometry = .{ .source = request.viewport, .viewport = request.viewport, .output = request.viewport, .axis = .page, .rtl = false };
    return .{ .frame = .{ .source = request.viewport, .geometry = frame_geometry, .position = anchor.position, .rect = .{ .x = 0, .y = 0, .width = request.viewport.width, .height = request.viewport.height }, .pixels = pixels, .revision = revision.final() }, .anchor = anchor, .at_end = at_end, .waiting = blocked, .last_visible_page = last, .content_height = filled };
}
