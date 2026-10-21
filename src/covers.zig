//! Small owned thumbnail cache. A frame pins images until rendering finishes.
const std = @import("std");
const Image = @import("reader-image");
const Cache = @This();
pub const capacity = 8;
pub const width = 160;
pub const height = 240;
const Entry = struct {
    path: []const u8,
    image: ?Image,
    used: u64,
};
entries: [capacity]?Entry = @splat(null),
frame: u64 = 1,

pub fn beginFrame(self: *Cache) void {
    self.frame +%= 1;
    if (self.frame == 0) {
        self.frame = 1;
        for (&self.entries) |*entry| if (entry.*) |*value| {
            value.used = 0;
        };
    }
}

fn release(gpa: std.mem.Allocator, entry: Entry) void {
    gpa.free(entry.path);
    if (entry.image) |image| gpa.free(image.pixels);
}

pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
    for (&self.entries) |*entry| if (entry.*) |value| {
        release(gpa, value);
        entry.* = null;
    };
}

/// `load` returns owned pixels. Decode failures are cached as placeholders;
/// allocator failures leave existing entries intact and can be retried.
pub fn get(self: *Cache, gpa: std.mem.Allocator, path: []const u8, context: anytype, comptime load: anytype) !?*Image {
    for (&self.entries) |*entry| if (entry.*) |*value| {
        if (std.mem.eql(u8, value.path, path)) {
            value.used = self.frame;
            return if (value.image) |*image| image else null;
        }
    };
    var victim: ?usize = null;
    for (self.entries, 0..) |entry, i| {
        if (entry == null) {
            victim = i;
            break;
        }
        if (entry.?.used == self.frame) continue;
        if (victim == null or entry.?.used < self.entries[victim.?].?.used) victim = i;
    }
    // Render commands may still borrow every entry; do not invalidate them.
    const index = victim orelse return null;
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    var image = load(context, path, width, height) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => failed: {
            std.log.warn("Cannot open cover {s}: {s}", .{ path, @errorName(err) });
            break :failed null;
        },
    };
    // Local/custom artwork may change in place. Damage tracking must see
    // changed pixels even when the relative path and layout remain identical.
    if (image) |*value| value.revision = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, path), value.pixels);
    if (self.entries[index]) |previous| release(gpa, previous);
    self.entries[index] = .{ .path = owned_path, .image = image, .used = self.frame };
    return if (self.entries[index].?.image) |*value| value else null;
}

const Fixture = struct {
    gpa: std.mem.Allocator,
    calls: usize = 0,
    shade: u8 = 42,
    fn load(self: *Fixture, path: []const u8, max_width: usize, max_height: usize) !Image {
        self.calls += 1;
        try std.testing.expectEqual(width, max_width);
        try std.testing.expectEqual(height, max_height);
        if (std.mem.eql(u8, path, "broken")) return error.InvalidBitmap;
        const pixels = try self.gpa.alloc(u8, 4);
        @memset(pixels, self.shade);
        return .{ .width = 2, .height = 2, .pixels = pixels, .revision = std.hash.Wyhash.hash(0, path) };
    }
};

test "thumbnail cache owns pixels, reuses failures, and pins current frame images" {
    const gpa = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    var fixture: Fixture = .{ .gpa = gpa };
    const first = (try cache.get(gpa, "first", &fixture, Fixture.load)).?;
    try std.testing.expect(first == (try cache.get(gpa, "first", &fixture, Fixture.load)).?);
    try std.testing.expect(try cache.get(gpa, "broken", &fixture, Fixture.load) == null);
    try std.testing.expect(try cache.get(gpa, "broken", &fixture, Fixture.load) == null);
    try std.testing.expectEqual(2, fixture.calls);
    for (0..capacity - 2) |i| {
        var path: [16]u8 = undefined;
        _ = try cache.get(gpa, try std.fmt.bufPrint(&path, "cover-{d}", .{i}), &fixture, Fixture.load);
    }
    try std.testing.expect(try cache.get(gpa, "overflow", &fixture, Fixture.load) == null);
    try std.testing.expectEqual(42, first.pixels[0]);
    try std.testing.expectEqual(capacity, fixture.calls);
    cache.beginFrame();
    try std.testing.expect(try cache.get(gpa, "overflow", &fixture, Fixture.load) != null);
    try std.testing.expectEqual(capacity + 1, fixture.calls);
}

fn allocationFailures(gpa: std.mem.Allocator) !void {
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    var fixture: Fixture = .{ .gpa = gpa };
    _ = try cache.get(gpa, "cover", &fixture, Fixture.load);
}

test "thumbnail cache cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}

test "changed thumbnail pixels at the same path invalidate rendered content" {
    const gpa = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    var fixture: Fixture = .{ .gpa = gpa };
    const original = (try cache.get(gpa, "cover", &fixture, Fixture.load)).?.revision;
    cache.deinit(gpa);
    fixture.shade = 43;
    const changed = (try cache.get(gpa, "cover", &fixture, Fixture.load)).?.revision;
    try std.testing.expect(original != changed);
    cache.deinit(gpa);
    try std.testing.expectEqual(changed, (try cache.get(gpa, "cover", &fixture, Fixture.load)).?.revision);
}
