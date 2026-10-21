//! Storage inspection runs in a cancellable fabrum task, away from input handling.
const std = @import("std");
const app = @import("fabrum").app;
const tachi = @import("tachi");
pub const Volume = struct { bytes: u64 = 0, cache: u64 = 0, covers: u64 = 0, other: u64 = 0, available: ?u64 = null, disk_total: ?u64 = null, used: ?u64 = null, present: bool = false };
pub const Snapshot = struct { internal: Volume, sd_card: Volume };
extern "c" fn pm_storage_free([*:0]const u8, *u64) c_int;

extern "c" fn pm_storage_capacity([*:0]const u8, *u64, *u64) c_int;

fn capacity(result: *Volume, path: [*:0]const u8) void {
    var total: u64 = 0;
    var used: u64 = 0;
    if (pm_storage_capacity(path, &total, &used) == 0) {
        result.disk_total = total;
        result.used = used;
    }
}

fn volume(task: *app.Task, path: []const u8) !Volume {
    try task.checkCancel();
    var dir = std.Io.Dir.cwd().openDir(task.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .present = true },
        else => return err,
    };
    defer dir.close(task.io);
    var result: Volume = .{ .present = true };
    const terminated = try task.gpa.dupeSentinel(u8, path, 0);
    defer task.gpa.free(terminated);
    var free: u64 = 0;
    if (pm_storage_free(terminated, &free) == 0) result.available = free;
    capacity(&result, terminated);
    var walker = try dir.walk(task.gpa);
    defer walker.deinit();
    while (try walker.next(task.io)) |entry| {
        try task.checkCancel();
        if (entry.kind != .file) continue;
        const stat = entry.dir.statFile(task.io, entry.basename, .{}) catch |err| switch (err) {
            // A background download can replace its temporary file during inspection.
            error.FileNotFound => continue,
            else => return err,
        };
        if (std.mem.startsWith(u8, entry.path, "downloads/")) {
            result.bytes += stat.size;
        } else if (std.mem.startsWith(u8, entry.path, "cache/")) {
            result.cache += stat.size;
        } else if (std.mem.startsWith(u8, entry.path, "covers/")) {
            result.covers += stat.size;
        } else result.other += stat.size;
    }
    return result;
}

pub fn inspect(task: *app.Task, engine: *tachi.Engine) anyerror!Snapshot {
    const internal = try volume(task, engine.options.dir);
    const sd: Volume = if (engine.sdAvailable()) blk: {
        // The volume can be present before PocketManga has downloaded to it.
        const root = engine.options.sd_dir.?;
        var value = try volume(task, root);
        if (value.available == null) {
            const parent = try task.gpa.dupeSentinel(u8, std.fs.path.dirname(root).?, 0);
            defer task.gpa.free(parent);
            var free: u64 = 0;
            if (pm_storage_free(parent, &free) == 0) value.available = free;
            capacity(&value, parent);
        }
        break :blk value;
    } else .{};
    return .{ .internal = internal, .sd_card = sd };
}

pub fn clearCache(task: *app.Task, engine: *tachi.Engine) anyerror!void {
    try task.checkCancel();
    try engine.clearChapterCache();
}
