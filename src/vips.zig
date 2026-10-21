//! Decoder-only libvips bridge. The library outlives every Image; each Image
//! is used serially; the bridge keeps its thread-affine VipsRegion call-local.
const std = @import("std");
const Init = *const fn () callconv(.c) c_int;
const Probe = *const fn ([*:0]const u8, *c_int, *c_int) callconv(.c) c_int;
const Open = *const fn ([*:0]const u8, f64, *c_int, *c_int) callconv(.c) ?*anyopaque;
const Region = *const fn (*anyopaque, c_int, c_int, c_int, c_int, [*]u8, usize) callconv(.c) c_int;
const Close = *const fn (*anyopaque) callconv(.c) void;
const Error = *const fn () callconv(.c) [*:0]const u8;
pub const Size = struct { width: usize, height: usize };
pub const Library = struct {
    handle: std.DynLib,
    probe_fn: Probe,
    open_fn: Open,
    region_fn: Region,
    close_fn: Close,
    error_fn: Error,
    pub fn load(path: []const u8) !Library {
        var handle = try std.DynLib.open(path);
        errdefer handle.close();
        const init = handle.lookup(Init, "pmi_init") orelse return error.MissingImageApi;
        const self: Library = .{
            .handle = handle,
            .probe_fn = handle.lookup(Probe, "pmi_probe") orelse return error.MissingImageApi,
            .open_fn = handle.lookup(Open, "pmi_open") orelse return error.MissingImageApi,
            .region_fn = handle.lookup(Region, "pmi_region") orelse return error.MissingImageApi,
            .close_fn = handle.lookup(Close, "pmi_close") orelse return error.MissingImageApi,
            .error_fn = handle.lookup(Error, "pmi_error") orelse return error.MissingImageApi,
        };
        if (init() != 0) return error.ImageInitializationFailed;
        return self;
    }
    pub fn deinit(self: *Library) void {
        // GLib registers process-global types and libvips keeps worker threads.
        // Their callbacks must remain mapped until process exit. Image handles
        // still release their pipelines promptly through Image.deinit.
        self.* = undefined;
    }
    pub fn diagnostic(self: *const Library) []const u8 {
        return std.mem.span(self.error_fn());
    }
    pub fn probe(self: *const Library, path: [:0]const u8) !Size {
        var w: c_int = 0;
        var h: c_int = 0;
        if (self.probe_fn(path.ptr, &w, &h) != 0) return error.ImageProbeFailed;
        if (w <= 0 or h <= 0) return error.InvalidImageDimensions;
        return .{ .width = @intCast(w), .height = @intCast(h) };
    }
    pub fn open(self: *const Library, path: [:0]const u8, scale: f64) !Image {
        var w: c_int = 0;
        var h: c_int = 0;
        const handle = self.open_fn(path.ptr, scale, &w, &h) orelse return error.ImageDecodeFailed;
        errdefer self.close_fn(handle);
        if (w <= 0 or h <= 0) return error.InvalidImageDimensions;
        return .{ .library = self, .handle = handle, .size = .{ .width = @intCast(w), .height = @intCast(h) } };
    }
};
pub const Image = struct {
    library: *const Library,
    handle: *anyopaque,
    size: Size,
    pub fn deinit(self: *Image) void {
        self.library.close_fn(self.handle);
        self.* = undefined;
    }
    pub fn region(self: *Image, x: usize, y: usize, width: usize, height: usize, pixels: []u8, stride: usize) !void {
        if (width == 0 or height == 0 or stride < width or width > self.size.width or height > self.size.height or x > self.size.width - width or y > self.size.height - height) return error.InvalidImageRegion;
        const needed = std.math.add(usize, std.math.mul(usize, stride, height - 1) catch return error.InvalidImageRegion, width) catch return error.InvalidImageRegion;
        if (pixels.len < needed) return error.InvalidImageRegion;
        if (self.library.region_fn(self.handle, @intCast(x), @intCast(y), @intCast(width), @intCast(height), pixels.ptr, stride) != 0) return error.ImageDecodeFailed;
    }
};
