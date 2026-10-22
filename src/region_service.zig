//! libvips is owned by serialized fabrum tasks, never by an input callback.
const std = @import("std");
const app = @import("fabrum").app;
const tachi = @import("tachi");
const vips = @import("vips.zig");
const cache = @import("region_cache.zig");
const vp = @import("reader_viewport.zig");
pub const Continuous = @import("continuous_reader.zig");

pub const Request = struct {
    requested_at_ms: ?i64 = null,
    mode: @import("library.zig").ReaderMode = .paged,
    delta: f64 = 0,
    pages: []const []const u8 = &.{},
    revision: usize = 0,
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
    /// At most two following source pages, copied into the task arena.
    next_pages: []const []const u8 = &.{},
};
pub const Result = struct {
    request: Request,
    ready_at: ?std.Io.Timestamp = null,
    value: union(enum) { frame: cache.Frame, continuous: Continuous.Output, failure: []const u8, prefetched },
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

pub fn continuousContext(service: *Service, io: std.Io, request: *const Request) Continuous.Context {
    return .{ .gpa = service.tiles.gpa, .io = io, .tiles = &service.tiles, .resolver = .{ .context = @ptrCast(@constCast(request)), .path = continuousPath } };
}

fn continuousPath(context: *anyopaque, arena: std.mem.Allocator, relative: []const u8) ![:0]const u8 {
    const request: *const Request = @ptrCast(@alignCast(context));
    if (!tachi.library.safePath(relative)) return error.UnsafePagePath;
    const path = if (request.engine) |engine| try engine.pagePath(arena, relative) else try std.fs.path.join(arena, &.{ request.root, relative });
    return arena.dupeSentinel(u8, path, 0);
}

pub fn continuousRequest(request: Request) Continuous.Request {
    return .{ .pages = request.pages, .anchor = .{ .page = request.page, .position = request.position }, .delta = request.delta, .viewport = request.viewport };
}

pub fn render(task: *app.Task, service: *Service, request: Request, on_frame: app.Handler(anyerror!Result)) anyerror!Result {
    try task.checkCancel();
    const started = std.Io.Clock.boot.now(task.io);
    const before = service.tiles.metrics;
    if (request.requested_at_ms) |at| std.log.info("Reader task page={d} delta={d:.1} input_to_start_ms={d}", .{ request.page + 1, request.delta, started.toMilliseconds() - at });
    if (request.mode == .vertical) {
        const context = continuousContext(service, task.io, &request);
        const output = try Continuous.render(context, task.gpa, continuousRequest(request), .{ .context = task, .check = checkpoint });
        try task.checkCancel();
        const ready_at = std.Io.Clock.boot.now(task.io);
        logRender(service, request, started, ready_at, before);
        try task.post(on_frame, @as(anyerror!Result, .{ .request = request, .ready_at = ready_at, .value = .{ .continuous = output } }));
        if (!output.at_end and !output.waiting) {
            var arena: std.heap.ArenaAllocator = .init(task.gpa);
            defer arena.deinit();
            const preparing = std.Io.Clock.boot.now(task.io);
            var next = continuousRequest(request);
            next.anchor = output.anchor;
            next.delta = @as(f64, @floatFromInt(request.viewport.height)) * 0.9;
            _ = Continuous.render(context, arena.allocator(), next, .{ .context = task, .check = checkpoint }) catch |err| {
                if (err == error.Canceled) return err;
                std.log.debug("Continuous preparation: {s}", .{@errorName(err)});
                return .{ .request = request, .value = .prefetched };
            };
            std.log.info("Reader continuous preparation_ms={d}", .{preparing.durationTo(std.Io.Clock.boot.now(task.io)).toMilliseconds()});
        }
        return .{ .request = request, .value = .prefetched };
    }
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
    const ready_at = std.Io.Clock.boot.now(task.io);
    logRender(service, request, started, ready_at, before);
    std.log.info("Reader region {s}: {d},{d} {d}x{d} ready decode_ms={d}", .{ request.relative, frame.rect.x, frame.rect.y, frame.rect.width, frame.rect.height, started.durationTo(ready_at).toMilliseconds() });
    // Publish the viewport before speculative work; borrowed task pixels stay
    // alive until message delivery, and canceled generations are discarded.
    try task.post(on_frame, @as(anyerror!Result, .{ .request = request, .ready_at = ready_at, .value = .{ .frame = frame } }));
    service.tiles.prefetch(task.io, frame.geometry, frame.rect, .{ .context = task, .check = checkpoint }) catch |err| {
        if (err == error.Canceled) return err;
        // A failed speculative neighbor must not replace the visible viewport.
        std.log.debug("Region prefetch: {s}", .{@errorName(err)});
    };
    // Finish the next screenful of a long image before opening other files.
    // The same geometry handles vertical webtoons and horizontal RTL/LTR pans.
    if (frame.geometry.step(frame.position, 1)) |position| {
        service.tiles.prepare(task.io, terminated, request.viewport, position, request.rtl, .{ .context = task, .check = checkpoint }) catch |err| {
            if (err == error.Canceled) return err;
            std.log.debug("Next region preparation: {s}", .{@errorName(err)});
        };
    }
    for (request.next_pages[0..@min(request.next_pages.len, 2)]) |relative| {
        try task.checkCancel();
        preparePage(task, service, request, relative) catch |err| {
            if (err == error.Canceled) return err;
            // A missing/corrupt future page cannot spoil the visible page.
            std.log.debug("Page preparation {s}: {s}", .{ relative, @errorName(err) });
        };
    }
    return .{ .request = request, .value = .prefetched };
}

fn preparePage(task: *app.Task, service: *Service, request: Request, relative: []const u8) !void {
    if (!tachi.library.safePath(relative)) return error.UnsafePagePath;
    var arena: std.heap.ArenaAllocator = .init(task.gpa);
    defer arena.deinit();
    const path = if (request.engine) |engine|
        try engine.pagePath(arena.allocator(), relative)
    else
        try std.fs.path.join(arena.allocator(), &.{ request.root, relative });
    const terminated = try arena.allocator().dupeSentinel(u8, path, 0);
    const started = std.Io.Clock.boot.now(task.io);
    try service.tiles.prepare(task.io, terminated, request.viewport, 0, request.rtl, .{ .context = task, .check = checkpoint });
    std.log.info("Reader prepared {s}: {d} ms", .{ relative, started.durationTo(std.Io.Clock.boot.now(task.io)).toMilliseconds() });
}

fn logRender(service: *Service, request: Request, started: std.Io.Timestamp, ready: std.Io.Timestamp, before: cache.Metrics) void {
    const m = service.tiles.metrics.since(before);
    std.log.info("Reader render mode={s} page={d} delta={d:.1} render_ms={d} ram_hits={d} disk_hits={d} decoded={d} open_us={d} disk_read_us={d} decode_us={d} disk_write_us={d}", .{ @tagName(request.mode), request.page + 1, request.delta, started.durationTo(ready).toMilliseconds(), m.ram_hits, m.disk_hits, m.decoded, m.open_us, m.disk_read_us, m.decode_us, m.disk_write_us });
}
