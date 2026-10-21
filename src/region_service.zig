//! libvips is owned by serialized fabrum tasks, never by an input callback.
const std = @import("std");
const app = @import("fabrum").app;
const tachi = @import("tachi");
const vips = @import("vips.zig");
const cache = @import("region_cache.zig");
const vp = @import("reader_viewport.zig");

pub const Request = struct {
    root: []const u8,
    relative: []const u8,
    chapter: []const u8,
    page: usize,
    epoch: u64,
    viewport: vp.Size,
    position: f64,
    backward: bool,
    rtl: bool,
    engine: ?*tachi.Engine = null,
};
pub const Result = struct {
    request: Request,
    value: union(enum) { frame: cache.Frame, failure: []const u8, prefetched },
};
const Adapter = struct {
    library: *const vips.Library,
    image: ?vips.Image = null,
    fn probe(ptr: *anyopaque, path: [:0]const u8) !vp.Size {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        const size = try self.library.probe(path);
        return .{ .width = @intCast(size.width), .height = @intCast(size.height) };
    }
    fn open(ptr: *anyopaque, path: [:0]const u8, scale: f64) !vp.Size {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        self.image = try self.library.open(path, scale);
        return .{ .width = @intCast(self.image.?.size.width), .height = @intCast(self.image.?.size.height) };
    }
    fn read(ptr: *anyopaque, rect: vp.Rect, pixels: []u8, stride: usize) !void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        try self.image.?.region(rect.x, rect.y, rect.width, rect.height, pixels, stride);
    }
    fn close(ptr: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        if (self.image) |*image| image.deinit();
        self.image = null;
    }
};
pub const Service = struct {
    adapter: Adapter,
    tiles: cache.Service,
    /// Initialize in its final address: the backend borrows `adapter`.
    pub fn init(self: *Service, gpa: std.mem.Allocator, library: *const vips.Library, cache_dir: []const u8) void {
        self.adapter = .{ .library = library };
        self.tiles = .init(gpa, .{ .context = &self.adapter, .probe = Adapter.probe, .open = Adapter.open, .read = Adapter.read, .close = Adapter.close }, cache_dir);
    }
    /// The host must join its declared tasks before destroying the service.
    pub fn deinit(self: *Service) void {
        self.tiles.deinit();
    }
};
fn checkpoint(context: ?*anyopaque) !void {
    const task: *app.Task = @ptrCast(@alignCast(context.?));
    try task.checkCancel();
}

pub fn render(task: *app.Task, service: *Service, request: Request, on_frame: app.Handler(anyerror!Result)) anyerror!Result {
    try task.checkCancel();
    if (!tachi.library.safePath(request.relative)) return error.UnsafePagePath;
    const path = if (request.engine) |engine|
        try engine.pagePath(task.gpa, request.relative)
    else
        try std.fs.path.join(task.gpa, &.{ request.root, request.relative });
    const terminated = try task.gpa.dupeSentinel(u8, path, 0);
    const frame = service.tiles.frame(task.gpa, task.io, terminated, request.viewport, request.position, request.backward, request.rtl, .{ .context = task, .check = checkpoint }) catch |err| {
        if (err == error.Canceled) return err;
        const diagnostic = service.adapter.library.diagnostic();
        const failure = try std.fmt.allocPrint(task.gpa, "{s}: {s}", .{ @errorName(err), diagnostic });
        std.log.warn("Cannot render {s}: {s}", .{ request.relative, failure });
        return .{ .request = request, .value = .{ .failure = failure } };
    };
    try task.checkCancel();
    std.log.info("Reader region {s}: {d},{d} {d}x{d} ready", .{ request.relative, frame.rect.x, frame.rect.y, frame.rect.width, frame.rect.height });
    // Publish the viewport before speculative work; borrowed task pixels stay
    // alive until message delivery, and canceled generations are discarded.
    try task.post(on_frame, @as(anyerror!Result, .{ .request = request, .value = .{ .frame = frame } }));
    service.tiles.prefetch(task.io, frame.geometry, frame.rect, .{ .context = task, .check = checkpoint }) catch |err| {
        if (err == error.Canceled) return err;
        // A failed speculative neighbor must not replace the visible viewport.
        std.log.debug("Region prefetch: {s}", .{@errorName(err)});
    };
    return .{ .request = request, .value = .prefetched };
}
