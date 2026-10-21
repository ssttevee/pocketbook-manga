const std = @import("std");
const continuous = @import("continuous_reader.zig");
const cache = @import("region_cache.zig");
const io = std.testing.io;

const Fake = struct {
    current: u8 = 0,
    tiny: bool = false,
    fail_page: ?u8 = null,
    reads: usize = 0,
    opens: usize = 0,
    fn self(p: *anyopaque) *Fake {
        return @ptrCast(@alignCast(p));
    }
    fn index(path: [:0]const u8) u8 {
        return path[path.len - 1] - '0';
    }
    fn probe(p: *anyopaque, path: [:0]const u8) !cache.Size {
        if (self(p).tiny) return .{ .width = 225, .height = 1 };
        return switch (index(path)) {
            0 => .{ .width = 1125, .height = 1500 },
            1 => .{ .width = 1125, .height = 100 },
            else => .{ .width = 2250, .height = 3000 },
        };
    }
    fn open(p: *anyopaque, path: [:0]const u8, scale: f64) !cache.Size {
        self(p).current = index(path);
        self(p).opens += 1;
        const size = try probe(p, path);
        return .{ .width = @intFromFloat(@round(@as(f64, @floatFromInt(size.width)) * scale)), .height = @intFromFloat(@round(@as(f64, @floatFromInt(size.height)) * scale)) };
    }
    fn read(p: *anyopaque, _: cache.Rect, pixels: []u8, _: usize) !void {
        self(p).reads += 1;
        if (self(p).fail_page == self(p).current) return error.BadImage;
        @memset(pixels, 10 + self(p).current);
    }
    fn close(_: *anyopaque) void {}
    fn resolve(_: *anyopaque, a: std.mem.Allocator, path: []const u8) ![:0]const u8 {
        return a.dupeSentinel(u8, path, 0);
    }
    fn backend(self_: *Fake) cache.Backend {
        return .{ .context = self_, .probe = probe, .open = open, .read = read, .close = close };
    }
};

const Fixture = struct {
    fn paths(a: std.mem.Allocator, dir: std.Io.Dir) ![]const []const u8 {
        const root = try dir.realPathFileAlloc(io, ".", a);
        const result = try a.alloc([]const u8, 3);
        for (result, 0..) |*path, i| {
            const name = try std.fmt.allocPrint(a, "{d}", .{i});
            try dir.writeFile(io, .{ .sub_path = name, .data = "fixture" });
            path.* = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, name });
        }
        return result;
    }
};

test "continuous view joins footer strips and different source widths without gaps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try Fixture.paths(a, tmp.dir);
    const disk = try std.fmt.allocPrint(a, "{s}/tiles", .{std.fs.path.dirname(paths[0]).?});
    var fake: Fake = .{};
    var tiles = cache.Service.init(std.testing.allocator, fake.backend(), disk);
    defer tiles.deinit();
    const ctx: continuous.Context = .{ .gpa = a, .io = io, .tiles = &tiles, .resolver = .{ .context = &fake, .path = Fake.resolve } };
    const request: continuous.Request = .{ .pages = paths, .anchor = .{ .page = 0, .position = 0.9 }, .viewport = .{ .width = 225, .height = 100 } };
    const result = try continuous.render(ctx, a, request, .{});
    try std.testing.expectEqual(@as(usize, 0), result.anchor.page);
    try std.testing.expectEqual(@as(usize, 2), result.last_visible_page);
    try std.testing.expect(!result.at_end and !result.waiting);
    for (0..100) |row| for (result.frame.pixels[row * 225 ..][0..225]) |pixel| {
        try std.testing.expectEqual(@as(u8, if (row < 30) 10 else if (row < 50) 11 else 12), pixel);
    };
    const reads = fake.reads;
    const opens = fake.opens;
    const cached = (try continuous.cached(ctx, a, request)).?;
    try std.testing.expectEqualSlices(u8, result.frame.pixels, cached.frame.pixels);
    try std.testing.expectEqual(reads, fake.reads);
    try std.testing.expectEqual(opens, fake.opens);
    // A paged wide strip uses different geometry and cannot contaminate webtoon tiles.
    const strip = try a.dupeSentinel(u8, paths[1], 0);
    _ = try tiles.frame(a, io, strip, request.viewport, 0, false, false, .{});
    const again = (try continuous.cached(ctx, a, request)).?;
    try std.testing.expectEqualSlices(u8, result.frame.pixels, again.frame.pixels);
    const next = try continuous.render(ctx, a, .{ .pages = paths, .anchor = result.anchor, .delta = 90, .viewport = request.viewport }, .{});
    try std.testing.expectEqual(@as(usize, 2), next.anchor.page);
    const prev = try continuous.render(ctx, a, .{ .pages = paths, .anchor = next.anchor, .delta = -90, .viewport = request.viewport }, .{});
    try std.testing.expectEqual(result.anchor.page, prev.anchor.page);
    try std.testing.expectApproxEqAbs(result.anchor.position, prev.anchor.position, 0.001);
    const end = try continuous.render(ctx, a, .{ .pages = paths, .anchor = .{ .page = 2 }, .delta = 99999, .viewport = request.viewport }, .{});
    try std.testing.expect(end.at_end);
    const start = try continuous.render(ctx, a, .{ .pages = paths, .anchor = result.anchor, .delta = -99999, .viewport = request.viewport }, .{});
    try std.testing.expectEqual(continuous.Anchor{ .page = 0 }, start.anchor);
}

test "continuous view preserves downloaded pixels while subsequent pages are unavailable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try Fixture.paths(a, tmp.dir);
    var fake: Fake = .{};
    var tiles = cache.Service.init(std.testing.allocator, fake.backend(), try std.fmt.allocPrint(a, "{s}/tiles", .{std.fs.path.dirname(paths[0]).?}));
    defer tiles.deinit();
    const ctx: continuous.Context = .{ .gpa = a, .io = io, .tiles = &tiles, .resolver = .{ .context = &fake, .path = Fake.resolve } };
    const missing = [_][]const u8{ paths[0], "", paths[2] };
    const result = try continuous.render(ctx, a, .{ .pages = &missing, .anchor = .{ .page = 0, .position = 0.9 }, .delta = 90, .viewport = .{ .width = 225, .height = 100 } }, .{});
    try std.testing.expect(result.waiting and !result.at_end);
    try std.testing.expectEqual(@as(usize, 0), result.anchor.page);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), result.anchor.position, 0.001);
    try std.testing.expectEqual(@as(u8, 10), result.frame.pixels[0]);
    try std.testing.expectEqual(@as(u8, 255), result.frame.pixels[30 * 225]);
    try std.testing.expectError(error.PageNotDownloaded, continuous.render(ctx, a, .{ .pages = &missing, .anchor = .{ .page = 1 }, .viewport = .{ .width = 225, .height = 100 } }, .{}));
    try std.testing.expect(fake.reads <= 2);
}

test "continuous composition checks cancellation between bounded image operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try Fixture.paths(a, tmp.dir);
    var fake: Fake = .{};
    var tiles = cache.Service.init(std.testing.allocator, fake.backend(), try std.fmt.allocPrint(a, "{s}/tiles", .{std.fs.path.dirname(paths[0]).?}));
    defer tiles.deinit();
    const ctx: continuous.Context = .{ .gpa = a, .io = io, .tiles = &tiles, .resolver = .{ .context = &fake, .path = Fake.resolve } };
    const Cancel = struct {
        checks: usize = 0,
        fn check(p: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            self.checks += 1;
            if (self.checks >= 5) return error.Canceled;
        }
    };
    var cancel: Cancel = .{};
    try std.testing.expectError(error.Canceled, continuous.render(ctx, a, .{ .pages = paths, .anchor = .{ .page = 0, .position = 0.9 }, .viewport = .{ .width = 225, .height = 100 } }, .{ .context = &cancel, .check = Cancel.check }));
    try std.testing.expectEqual(@as(usize, 5), cancel.checks);
    try std.testing.expect(fake.reads <= 1);
}

test "continuous composition bounds work even for hundreds of single-pixel strips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try Fixture.paths(a, tmp.dir);
    var fake: Fake = .{ .tiny = true };
    var tiles = cache.Service.init(std.testing.allocator, fake.backend(), try std.fmt.allocPrint(a, "{s}/tiles", .{std.fs.path.dirname(paths[0]).?}));
    defer tiles.deinit();
    const ctx: continuous.Context = .{ .gpa = a, .io = io, .tiles = &tiles, .resolver = .{ .context = &fake, .path = Fake.resolve } };
    const repeated: [200][]const u8 = @splat(paths[0]);
    try std.testing.expectError(error.TooManyContinuousImages, continuous.render(ctx, a, .{ .pages = &repeated, .anchor = .{ .page = 0 }, .viewport = .{ .width = 225, .height = 200 } }, .{}));
    try std.testing.expectEqual(@as(usize, 1), fake.reads);
}

test "continuous following image decode failure retains the already drawn page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try Fixture.paths(a, tmp.dir);
    var fake: Fake = .{ .fail_page = 1 };
    var tiles = cache.Service.init(std.testing.allocator, fake.backend(), try std.fmt.allocPrint(a, "{s}/tiles", .{std.fs.path.dirname(paths[0]).?}));
    defer tiles.deinit();
    const ctx: continuous.Context = .{ .gpa = a, .io = io, .tiles = &tiles, .resolver = .{ .context = &fake, .path = Fake.resolve } };
    const result = try continuous.render(ctx, a, .{ .pages = paths, .anchor = .{ .page = 0, .position = 0.9 }, .viewport = .{ .width = 225, .height = 100 } }, .{});
    try std.testing.expect(result.waiting and !result.at_end);
    try std.testing.expectEqual(@as(usize, 0), result.last_visible_page);
    try std.testing.expectEqual(@as(u8, 10), result.frame.pixels[29 * 225]);
    try std.testing.expectEqual(@as(u8, 255), result.frame.pixels[30 * 225]);
}
