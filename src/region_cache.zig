//! Bounded display-resolution tiles. Only a serialized background reader task
//! touches this service; the UI receives its own immutable viewport pixels.
const std = @import("std");
const vp = @import("reader_viewport.zig");
pub const Size = vp.Size;
pub const Rect = vp.Rect;
pub const Backend = struct {
    context: *anyopaque,
    probe: *const fn (*anyopaque, [:0]const u8) anyerror!Size,
    open: *const fn (*anyopaque, [:0]const u8, f64) anyerror!Size,
    read: *const fn (*anyopaque, Rect, []u8, usize) anyerror!void,
    close: *const fn (*anyopaque) void,
};
pub const Checkpoint = struct {
    context: ?*anyopaque = null,
    check: ?*const fn (?*anyopaque) anyerror!void = null,
    fn run(self: Checkpoint, io: std.Io) !void {
        if (self.check) |check| try check(self.context) else try io.checkCancel();
    }
};
pub const Frame = struct {
    source: Size,
    geometry: vp.Geometry,
    position: f64,
    rect: Rect,
    pixels: []u8,
    revision: u64,
};
const Tile = struct { x: u32, y: u32, width: u32, height: u32, pixels: []u8, used: u64 };
pub const Service = struct {
    pub const tile_size = 256;
    pub const capacity = 16;
    pub const disk_limit = 64 * 1024 * 1024;
    gpa: std.mem.Allocator,
    backend: Backend,
    cache_dir: []const u8,
    key: ?u64 = null,
    source: Size = .{ .width = 0, .height = 0 },
    geometry: ?vp.Geometry = null,
    tiles: [capacity]?Tile = @splat(null),
    clock: u64 = 0,
    disk_scanned: bool = false,
    disk_written: usize = 0,

    pub fn init(gpa: std.mem.Allocator, backend: Backend, cache_dir: []const u8) Service {
        return .{ .gpa = gpa, .backend = backend, .cache_dir = cache_dir };
    }
    fn clear(self: *Service) void {
        for (&self.tiles) |*tile| if (tile.*) |value| {
            self.gpa.free(value.pixels);
            tile.* = null;
        };
        if (self.key != null) self.backend.close(self.backend.context);
        self.key = null;
        self.geometry = null;
    }
    pub fn deinit(self: *Service) void {
        self.clear();
    }

    /// Output is allocated in the caller's result arena, independent of tiles.
    pub fn frame(self: *Service, arena: std.mem.Allocator, io: std.Io, path: [:0]const u8, view: Size, progress: f64, backward: bool, rtl: bool, checkpoint: Checkpoint) !Frame {
        try checkpoint.run(io);
        if (view.width == 0 or view.height == 0 or view.width > 8192 or view.height > 8192) return error.InvalidViewport;
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        var hash = std.hash.Wyhash.init(0x504d524547494f4e);
        hash.update(path);
        hash.update(std.mem.asBytes(&stat.size));
        // i96 has padding in its native representation. Hash only the twelve
        // meaningful bytes so identical timestamps survive process recreation.
        var timestamp: [12]u8 = undefined;
        std.mem.writeInt(i96, &timestamp, stat.mtime.nanoseconds, .little);
        hash.update(&timestamp);
        hash.update(std.mem.asBytes(&view.width));
        hash.update(std.mem.asBytes(&view.height));
        // Include pipeline version: cached pixels must change with filters.
        hash.update("gray-white-lanczos3-v1");
        const key = hash.final();
        if (self.key != key) {
            self.clear();
            const source = try self.backend.probe(self.backend.context, path);
            if (source.width == 0 or source.height == 0) return error.InvalidImageDimensions;
            try checkpoint.run(io);
            var geometry = vp.Geometry.init(source, view, rtl);
            const scale = switch (geometry.axis) {
                .vertical => @as(f64, @floatFromInt(view.width)) / @as(f64, @floatFromInt(source.width)),
                .horizontal => @as(f64, @floatFromInt(view.height)) / @as(f64, @floatFromInt(source.height)),
                .page => @min(@as(f64, @floatFromInt(view.width)) / @as(f64, @floatFromInt(source.width)), @as(f64, @floatFromInt(view.height)) / @as(f64, @floatFromInt(source.height))),
            };
            const output = try self.backend.open(self.backend.context, path, scale);
            errdefer self.backend.close(self.backend.context);
            // Keep tile iteration additions representable, even for a corrupt
            // header or a backend returning impossible dimensions.
            if (output.width == 0 or output.height == 0 or output.width > std.math.maxInt(u32) - tile_size or output.height > std.math.maxInt(u32) - tile_size) return error.InvalidImageDimensions;
            geometry.output = output;
            self.source = source;
            self.geometry = geometry;
            self.key = key;
        }
        var geometry = self.geometry.?;
        geometry.rtl = rtl;
        const position = if (backward) @as(f64, 1) else vp.clamp(progress);
        const rect = geometry.region(position);
        const pixels = try arena.alloc(u8, @as(usize, rect.width) * rect.height);
        errdefer arena.free(pixels);
        if (!self.disk_scanned) {
            self.prune(io) catch {};
            self.disk_scanned = true;
        }
        var y = rect.y / tile_size * tile_size;
        while (y < rect.y + rect.height) : (y += tile_size) {
            var x = rect.x / tile_size * tile_size;
            while (x < rect.x + rect.width) : (x += tile_size) {
                try checkpoint.run(io);
                const tile = try self.getTile(io, x, y, checkpoint);
                const left = @max(x, rect.x);
                const top = @max(y, rect.y);
                const right = @min(x + tile.width, rect.x + rect.width);
                const bottom = @min(y + tile.height, rect.y + rect.height);
                for (top..bottom) |row| {
                    const src = (row - y) * tile.width + left - x;
                    const dst = (row - rect.y) * rect.width + left - rect.x;
                    @memcpy(pixels[dst..][0 .. right - left], tile.pixels[src..][0 .. right - left]);
                }
            }
        }
        try checkpoint.run(io);
        return .{ .source = self.source, .geometry = geometry, .position = position, .rect = rect, .pixels = pixels, .revision = std.hash.Wyhash.hash(key, std.mem.asBytes(&rect)) };
    }

    /// Warm one adjacent tile band after the visible frame has been published.
    pub fn prefetch(self: *Service, io: std.Io, geometry: vp.Geometry, rect: Rect, checkpoint: Checkpoint) !void {
        if (self.key == null or self.geometry == null) return;
        try checkpoint.run(io);
        switch (geometry.axis) {
            .page => return,
            .vertical => {
                const edge = rect.y + rect.height;
                if (edge >= geometry.output.height) return;
                // The last visible row is already cached. Warm the next one.
                const y = ((edge - 1) / tile_size + 1) * tile_size;
                if (y >= geometry.output.height) return;
                var x = rect.x / tile_size * tile_size;
                while (x < rect.x + rect.width) : (x += tile_size) {
                    try checkpoint.run(io);
                    _ = try self.getTile(io, x, y, checkpoint);
                }
            },
            .horizontal => {
                const x = if (geometry.rtl) blk: {
                    const left = rect.x / tile_size * tile_size;
                    if (left == 0) return;
                    break :blk left - tile_size;
                } else blk: {
                    const edge = rect.x + rect.width;
                    if (edge >= geometry.output.width) return;
                    const right = ((edge - 1) / tile_size + 1) * tile_size;
                    if (right >= geometry.output.width) return;
                    break :blk right;
                };
                var y = rect.y / tile_size * tile_size;
                while (y < rect.y + rect.height) : (y += tile_size) {
                    try checkpoint.run(io);
                    _ = try self.getTile(io, x, y, checkpoint);
                }
            },
        }
    }

    fn getTile(self: *Service, io: std.Io, x: u32, y: u32, checkpoint: Checkpoint) !Tile {
        self.clock +%= 1;
        for (&self.tiles) |*slot| if (slot.*) |*tile| {
            if (tile.x == x and tile.y == y) {
                tile.used = self.clock;
                return tile.*;
            }
        };
        var index: usize = 0;
        for (self.tiles, 0..) |slot, i| {
            if (slot == null) {
                index = i;
                break;
            }
            if (slot.?.used < self.tiles[index].?.used) index = i;
        }
        const size = self.geometry.?.output;
        const width = @min(tile_size, size.width - x);
        const height = @min(tile_size, size.height - y);
        const pixels = try self.gpa.alloc(u8, @as(usize, width) * height);
        errdefer self.gpa.free(pixels);
        const tile: Tile = .{ .x = x, .y = y, .width = width, .height = height, .pixels = pixels, .used = self.clock };
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{x}-{d}-{d}.tile", .{ self.cache_dir, self.key.?, x, y });
        if (!try self.readDisk(io, path, tile)) {
            try checkpoint.run(io);
            try self.backend.read(self.backend.context, .{ .x = x, .y = y, .width = width, .height = height }, pixels, width);
            try checkpoint.run(io);
            self.writeDisk(io, path, tile) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {}, // Optional cache: reading must also work on full storage.
            };
        }
        if (self.tiles[index]) |old| self.gpa.free(old.pixels);
        self.tiles[index] = tile;
        return tile;
    }
    fn readDisk(self: *Service, io: std.Io, path: []const u8, tile: Tile) !bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(tile.pixels.len + 17)) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => return false,
        };
        defer self.gpa.free(bytes);
        if (bytes.len != tile.pixels.len + 16 or !std.mem.eql(u8, bytes[0..4], "PMT1")) return false;
        if (std.mem.readInt(u16, bytes[4..6], .little) != tile.width or std.mem.readInt(u16, bytes[6..8], .little) != tile.height) return false;
        if (std.mem.readInt(u64, bytes[8..16], .little) != std.hash.Wyhash.hash(0, bytes[16..])) return false;
        @memcpy(tile.pixels, bytes[16..]);
        return true;
    }
    fn writeDisk(self: *Service, io: std.Io, path: []const u8, tile: Tile) !void {
        try std.Io.Dir.cwd().createDirPath(io, self.cache_dir);
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
        errdefer {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        }
        var header: [16]u8 = undefined;
        @memcpy(header[0..4], "PMT1");
        std.mem.writeInt(u16, header[4..6], @intCast(tile.width), .little);
        std.mem.writeInt(u16, header[6..8], @intCast(tile.height), .little);
        std.mem.writeInt(u64, header[8..16], std.hash.Wyhash.hash(0, tile.pixels), .little);
        {
            const file = try std.Io.Dir.cwd().createFile(io, tmp, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, &header);
            try file.writeStreamingAll(io, tile.pixels);
        }
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
        self.disk_written += header.len + tile.pixels.len;
        if (self.disk_written >= 1024 * 1024) {
            try self.prune(io);
            self.disk_written = 0;
        }
    }
    fn prune(self: *Service, io: std.Io) !void {
        var dir = std.Io.Dir.cwd().openDir(io, self.cache_dir, .{ .iterate = true }) catch return;
        defer dir.close(io);
        const Entry = struct { name: []const u8, size: u64, time: i128 };
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var entries: std.ArrayList(Entry) = .empty;
        var total: u64 = 0;
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".tile.tmp")) {
                try dir.deleteFile(io, entry.name);
                continue;
            }
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".tile")) continue;
            if (entries.items.len >= 2048) {
                dir.deleteFile(io, entry.name) catch {};
                continue;
            }
            const stat = try dir.statFile(io, entry.name, .{});
            total += stat.size;
            try entries.append(arena.allocator(), .{ .name = try arena.allocator().dupe(u8, entry.name), .size = stat.size, .time = stat.mtime.nanoseconds });
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.time < b.time;
            }
        }.less);
        for (entries.items) |entry| {
            if (total <= disk_limit) break;
            try dir.deleteFile(io, entry.name);
            total -= entry.size;
        }
    }
};
