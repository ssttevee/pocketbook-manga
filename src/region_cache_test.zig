const std = @import("std");
const cache = @import("region_cache.zig");
const vp = @import("reader_viewport.zig");
const io = std.testing.io;

const Fake = struct {
    source: cache.Size = .{ .width = 1000, .height = 10000 },
    output_override: ?cache.Size = null,
    output: cache.Size = undefined,
    reads: usize = 0,
    opens: usize = 0,
    closes: usize = 0,
    canceled: bool = false,
    cancel_on_read: bool = false,
    fn ptr(context: *anyopaque) *Fake {
        return @ptrCast(@alignCast(context));
    }
    fn probe(context: *anyopaque, _: [:0]const u8) !cache.Size {
        return ptr(context).source;
    }
    fn open(context: *anyopaque, _: [:0]const u8, scale: f64) !cache.Size {
        const self = ptr(context);
        self.opens += 1;
        self.output = self.output_override orelse .{
            .width = @intFromFloat(@round(@as(f64, @floatFromInt(self.source.width)) * scale)),
            .height = @intFromFloat(@round(@as(f64, @floatFromInt(self.source.height)) * scale)),
        };
        return self.output;
    }
    fn pixel(x: u32, y: u32) u8 {
        return @intCast((@as(u64, x) * 7 + @as(u64, y) * 11) % 251);
    }
    fn read(context: *anyopaque, rect: cache.Rect, pixels: []u8, stride: usize) !void {
        const self = ptr(context);
        self.reads += 1;
        for (0..rect.height) |y| for (0..rect.width) |x| {
            pixels[y * stride + x] = pixel(rect.x + @as(u32, @intCast(x)), rect.y + @as(u32, @intCast(y)));
        };
        if (self.cancel_on_read) self.canceled = true;
    }
    fn close(context: *anyopaque) void {
        ptr(context).closes += 1;
    }
    fn check(context: ?*anyopaque) !void {
        if (ptr(context.?).canceled) return error.Canceled;
    }
    fn backend(self: *Fake) cache.Backend {
        return .{ .context = self, .probe = probe, .open = open, .read = read, .close = close };
    }
    fn checkpoint(self: *Fake) cache.Checkpoint {
        return .{ .context = self, .check = check };
    }
};
const Paths = struct { image: [:0]const u8, disk: []const u8 };
fn paths(a: std.mem.Allocator, dir: std.Io.Dir) !Paths {
    try dir.writeFile(io, .{ .sub_path = "image", .data = "fixture" });
    const root = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const image = try std.fmt.allocPrintSentinel(a, "{s}/image", .{root}, 0);
    errdefer a.free(image);
    return .{ .image = image, .disk = try std.fmt.allocPrint(a, "{s}/tiles", .{root}) };
}
fn expectPixels(frame: cache.Frame) !void {
    try std.testing.expectEqual(@as(usize, frame.rect.width) * frame.rect.height, frame.pixels.len);
    for (0..frame.rect.height) |y| for (0..frame.rect.width) |x| {
        try std.testing.expectEqual(Fake.pixel(frame.rect.x + @as(u32, @intCast(x)), frame.rect.y + @as(u32, @intCast(y))), frame.pixels[y * frame.rect.width + x]);
    };
}

test "region tiles compose both axes without seams and keep pixels independent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    for ([_]cache.Size{ .{ .width = 1000, .height = 10000 }, .{ .width = 10000, .height = 1000 } }) |source| {
        var fake: Fake = .{ .source = source };
        var service = cache.Service.init(std.testing.allocator, fake.backend(), p.disk);
        defer service.deinit();
        const view: cache.Size = .{ .width = 613, .height = 709 };
        const frame = try service.frame(arena.allocator(), io, p.image, view, 0.37, false, true, .{});
        try expectPixels(frame);
        const before = try arena.allocator().dupe(u8, frame.pixels);
        const next = try service.frame(arena.allocator(), io, p.image, view, 0.81, false, true, .{});
        try expectPixels(next);
        try std.testing.expectEqualSlices(u8, before, frame.pixels);
        var count: usize = 0;
        var bytes: usize = 0;
        for (service.tiles) |entry| if (entry) |tile| {
            count += 1;
            bytes += tile.pixels.len;
        };
        try std.testing.expect(count <= cache.Service.capacity);
        try std.testing.expect(bytes <= cache.Service.capacity * cache.Service.tile_size * cache.Service.tile_size);
        service.deinit();
        try std.testing.expectEqual(@as(usize, 1), fake.closes);
    }
}

test "normal pages retain their fitted dimensions and backend rounding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    var fake: Fake = .{ .source = .{ .width = 700, .height = 1000 }, .output_override = .{ .width = 629, .height = 899 } };
    var service = cache.Service.init(std.testing.allocator, fake.backend(), p.disk);
    defer service.deinit();
    const frame = try service.frame(arena.allocator(), io, p.image, .{ .width = 758, .height = 900 }, 0, false, false, .{});
    try std.testing.expectEqual(vp.Axis.page, frame.geometry.axis);
    try std.testing.expectEqual(fake.output, frame.geometry.output);
    try std.testing.expectEqual(cache.Rect{ .x = 0, .y = 0, .width = 629, .height = 899 }, frame.rect);
    try expectPixels(frame);
}

test "disk tiles survive service recreation and corrupt tiles regenerate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    const view: cache.Size = .{ .width = 200, .height = 200 };
    var fake: Fake = .{};
    var service = cache.Service.init(std.testing.allocator, fake.backend(), p.disk);
    _ = try service.frame(arena.allocator(), io, p.image, view, 0, false, false, .{});
    const key = service.key.?;
    const first_reads = fake.reads;
    try std.testing.expect(first_reads > 0);
    service.deinit();
    service = cache.Service.init(std.testing.allocator, fake.backend(), p.disk);
    defer service.deinit();
    const reused = try service.frame(arena.allocator(), io, p.image, view, 0, false, false, .{});
    try expectPixels(reused);
    try std.testing.expectEqual(key, service.key.?);
    try std.testing.expectEqual(first_reads, fake.reads);
    service.deinit();
    service = cache.Service.init(std.testing.allocator, fake.backend(), p.disk);
    const tile = try std.fmt.allocPrint(arena.allocator(), "{s}/{x}-0-0.tile", .{ p.disk, key });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tile, .data = "corrupt" });
    const repaired = try service.frame(arena.allocator(), io, p.image, view, 0, false, false, .{});
    try expectPixels(repaired);
    try std.testing.expectEqual(first_reads + 1, fake.reads);
}

test "mtime invalidates cached pixels even when source size is unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    var fake: Fake = .{};
    var service = cache.Service.init(std.testing.allocator, fake.backend(), p.disk);
    defer service.deinit();
    const view: cache.Size = .{ .width = 200, .height = 200 };
    _ = try service.frame(arena.allocator(), io, p.image, view, 0, false, false, .{});
    const old_key = service.key.?;
    const file = try tmp.dir.openFile(io, "image", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = stat.mtime.nanoseconds + std.time.ns_per_s * 2 } } });
    _ = try service.frame(arena.allocator(), io, p.image, view, 0, false, false, .{});
    try std.testing.expect(service.key.? != old_key);
    try std.testing.expectEqual(@as(usize, 2), fake.opens);
    try std.testing.expectEqual(@as(usize, 1), fake.closes);
}

test "cancellation after decoding never publishes or caches the canceled tile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    var fake: Fake = .{ .cancel_on_read = true };
    var service = cache.Service.init(std.testing.allocator, fake.backend(), p.disk);
    defer service.deinit();
    try std.testing.expectError(error.Canceled, service.frame(std.testing.allocator, io, p.image, .{ .width = 200, .height = 200 }, 0, false, false, fake.checkpoint()));
    for (service.tiles) |tile| try std.testing.expect(tile == null);
    fake.canceled = false;
    fake.cancel_on_read = false;
    const frame = try service.frame(arena.allocator(), io, p.image, .{ .width = 200, .height = 200 }, 0, false, false, fake.checkpoint());
    try expectPixels(frame);
}

test "invalid viewport and image dimensions fail before allocation or tile arithmetic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    var fake: Fake = .{};
    var service = cache.Service.init(std.testing.allocator, fake.backend(), p.disk);
    defer service.deinit();
    for ([_]cache.Size{ .{ .width = 0, .height = 1 }, .{ .width = 8193, .height = 1 } }) |view|
        try std.testing.expectError(error.InvalidViewport, service.frame(std.testing.allocator, io, p.image, view, 0, false, false, .{}));
    fake.source.width = 0;
    try std.testing.expectError(error.InvalidImageDimensions, service.frame(std.testing.allocator, io, p.image, .{ .width = 1, .height = 1 }, 0, false, false, .{}));
    fake.source.width = 1000;
    fake.output_override = .{ .width = std.math.maxInt(u32), .height = 1 };
    try std.testing.expectError(error.InvalidImageDimensions, service.frame(std.testing.allocator, io, p.image, .{ .width = 1, .height = 1 }, 0, false, false, .{}));
    try std.testing.expectEqual(@as(usize, 1), fake.closes);
    try std.testing.expect(service.key == null);
}

fn withAllocationFailures(a: std.mem.Allocator, image: [:0]const u8, disk: []const u8) !void {
    var fake: Fake = .{};
    var service = cache.Service.init(a, fake.backend(), disk);
    defer service.deinit();
    const frame = try service.frame(a, io, image, .{ .width = 300, .height = 300 }, 0.4, false, false, .{});
    defer a.free(frame.pixels);
    try expectPixels(frame);
}
test "viewport and tile allocation failures release partial results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    // A regular file as the parent disables the optional disk cache, isolating
    // ownership of mandatory viewport and tile buffers under allocation failure.
    const disk = try std.fmt.allocPrint(arena.allocator(), "{s}/cache", .{p.image});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, withAllocationFailures, .{ p.image, disk });
}

test "prefetch warms one adjacent band for vertical and both horizontal directions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    const disk = try std.fmt.allocPrint(arena.allocator(), "{s}/cache", .{p.image});
    for ([_]struct { source: cache.Size, rtl: bool }{
        .{ .source = .{ .width = 1000, .height = 10000 }, .rtl = true },
        .{ .source = .{ .width = 10000, .height = 1000 }, .rtl = false },
        .{ .source = .{ .width = 10000, .height = 1000 }, .rtl = true },
    }) |case| {
        var fake: Fake = .{ .source = case.source };
        var service = cache.Service.init(std.testing.allocator, fake.backend(), disk);
        defer service.deinit();
        const frame = try service.frame(arena.allocator(), io, p.image, .{ .width = 300, .height = 300 }, 0, false, case.rtl, .{});
        const before = fake.reads;
        try service.prefetch(io, frame.geometry, frame.rect, .{});
        try std.testing.expectEqual(before + 2, fake.reads);
        try service.prefetch(io, frame.geometry, frame.rect, .{});
        try std.testing.expectEqual(before + 2, fake.reads);
        const end = try service.frame(arena.allocator(), io, p.image, .{ .width = 300, .height = 300 }, 1, false, case.rtl, .{});
        const at_end = fake.reads;
        try service.prefetch(io, end.geometry, end.rect, .{});
        try std.testing.expectEqual(at_end, fake.reads);
        fake.canceled = true;
        try std.testing.expectError(error.Canceled, service.prefetch(io, end.geometry, end.rect, fake.checkpoint()));
    }
}

test "tile LRU evicts old regions without retaining more than its capacity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    const disk = try std.fmt.allocPrint(arena.allocator(), "{s}/cache", .{p.image});
    var fake: Fake = .{ .source = .{ .width = 1000, .height = 30000 } };
    var service = cache.Service.init(std.testing.allocator, fake.backend(), disk);
    defer service.deinit();
    const view: cache.Size = .{ .width = 300, .height = 300 };
    for (0..20) |i| {
        _ = try service.frame(arena.allocator(), io, p.image, view, @as(f64, @floatFromInt(i)) / 19, false, false, .{});
        var count: usize = 0;
        for (service.tiles) |tile| if (tile != null) {
            count += 1;
        };
        try std.testing.expect(count <= cache.Service.capacity);
    }
    const before = fake.reads;
    const first = try service.frame(arena.allocator(), io, p.image, view, 0, false, false, .{});
    try expectPixels(first);
    try std.testing.expect(fake.reads > before);
    const after = fake.reads;
    _ = try service.frame(arena.allocator(), io, p.image, view, 0, false, false, .{});
    try std.testing.expectEqual(after, fake.reads);
}

test "prepared following pages reuse tiles in both axes after other pages and validate file changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try paths(arena.allocator(), tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "next", .data = "next fixture" });
    const next = try std.fmt.allocPrintSentinel(arena.allocator(), "{s}/../next", .{p.disk}, 0);
    for ([_]cache.Size{ .{ .width = 1000, .height = 10000 }, .{ .width = 10000, .height = 1000 } }) |source| {
        for ([_]bool{ false, true }) |rtl| {
            var fake: Fake = .{ .source = source };
            var service = cache.Service.init(std.testing.allocator, fake.backend(), p.disk);
            defer service.deinit();
            const view: cache.Size = .{ .width = 613, .height = 709 };
            const current = try service.frame(arena.allocator(), io, p.image, view, 0, false, rtl, .{});
            const snapshot = try arena.allocator().dupe(u8, current.pixels);
            const position = current.geometry.step(0, 1).?;
            try service.prepare(io, p.image, view, position, rtl, .{});
            const region_reads = fake.reads;
            const region = try service.frame(arena.allocator(), io, p.image, view, position, false, rtl, .{});
            try std.testing.expectEqual(region_reads, fake.reads);
            try expectPixels(region);
            try service.prepare(io, next, view, 0, rtl, .{});
            // Moving back to the old page evicts the prepared page from RAM.
            _ = try service.frame(arena.allocator(), io, p.image, view, 0, false, rtl, .{});
            const reads = fake.reads;
            const prepared = try service.frame(arena.allocator(), io, next, view, 0, false, rtl, .{});
            try std.testing.expectEqual(reads, fake.reads);
            try expectPixels(prepared);
            try std.testing.expectEqualSlices(u8, snapshot, current.pixels);
            if (prepared.geometry.axis == .horizontal) try std.testing.expectEqual(rtl, prepared.rect.x > 0);
            // Changed files must not use previously prepared pixels.
            try tmp.dir.writeFile(io, .{ .sub_path = "next", .data = "replacement fixture with a different size" });
            try service.prepare(io, next, view, 0, rtl, .{});
            try std.testing.expect(fake.reads > reads);
            fake.canceled = true;
            const before_cancel = fake.reads;
            try std.testing.expectError(error.Canceled, service.prepare(io, next, view, 0, rtl, fake.checkpoint()));
            try std.testing.expectEqual(before_cancel, fake.reads);
            try tmp.dir.writeFile(io, .{ .sub_path = "next", .data = "next fixture" });
        }
    }
}
