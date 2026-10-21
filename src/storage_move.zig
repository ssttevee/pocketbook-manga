//! Move saved chapter trees without exposing half-copied pages to the reader.
const std = @import("std");
const tachi = @import("tachi");
const Io = std.Io;
extern "c" fn pm_storage_free([*:0]const u8, *u64) c_int;
pub const Cancel = struct {
    context: *anyopaque,
    check: *const fn (*anyopaque) anyerror!void,
    fn poll(self: ?Cancel) !void {
        if (self) |c| try c.check(c.context);
    }
};

fn emptyDestination(io: Io, path: []const u8) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| if (entry.kind != .file or !std.mem.eql(u8, entry.name, "destination.json")) return error.DestinationHasDownloads;
}

fn treeSize(a: std.mem.Allocator, io: Io, path: []const u8, cancel: ?Cancel) !u64 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var bytes: u64 = 0;
    while (try walker.next(io)) |entry| {
        try Cancel.poll(cancel);
        switch (entry.kind) {
            .file => bytes += (try entry.dir.statFile(io, entry.basename, .{})).size,
            .directory => {},
            else => return error.UnsupportedDownloadFile,
        }
    }
    return bytes;
}

fn copyTree(a: std.mem.Allocator, io: Io, source: []const u8, target: []const u8, cancel: ?Cancel) !void {
    var dir = try Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    try Io.Dir.cwd().createDirPath(io, target);
    var buffer: [64 * 1024]u8 = undefined;
    while (try walker.next(io)) |entry| {
        try Cancel.poll(cancel);
        const path = try std.fs.path.join(a, &.{ target, entry.path });
        if (entry.kind == .directory) {
            try Io.Dir.cwd().createDirPath(io, path);
        } else if (entry.kind == .file) {
            // Destination markers live on internal storage independently of pages.
            if (std.mem.eql(u8, entry.path, "destination.json")) continue;
            try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
            const input = try entry.dir.openFile(io, entry.basename, .{});
            defer input.close(io);
            const output = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
            defer output.close(io);
            while (true) {
                try Cancel.poll(cancel);
                const n = input.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                try output.writeStreamingAll(io, buffer[0..n]);
            }
            try output.sync(io);
        } else return error.UnsupportedDownloadFile;
    }
}

/// One chapter commits at a time. Cancellation/failure preserves every source
/// not yet committed; already moved chapters remain available on the new disk.
pub fn move(engine: *tachi.Engine, ids: []const []const u8, sd: bool, cancel: ?Cancel) !usize {
    if (engine.queue.running()) return error.DownloadQueueRunning;
    if (sd and !engine.sdAvailable()) return error.StorageUnavailable;
    var arena: std.heap.ArenaAllocator = .init(engine.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = engine.io;
    const target_root = if (sd) engine.options.sd_dir.? else engine.options.dir;
    const lib = try engine.loadLibrary(a);
    const Item = struct { id: []const u8, source: []const u8, target: []const u8, source_sd: bool, pages: []const []const u8 };
    var items: std.ArrayList(Item) = .empty;
    var required: u64 = 0;
    for (lib.manga) |manga| {
        if (manga.local()) continue;
        for (manga.chapters) |chapter| {
            var selected = false;
            for (ids) |id| if (std.mem.eql(u8, id, chapter.id)) {
                selected = true;
                break;
            };
            if (!selected) continue;
            try Cancel.poll(cancel);
            const destination = try engine.downloadTarget(a, chapter.id);
            const source_sd = if (chapter.pages.len > 0) std.mem.startsWith(u8, chapter.pages[0], "sdcard/") else destination.sd_card;
            if (source_sd == sd) continue;
            if (source_sd and !engine.sdAvailable()) return error.StorageUnavailable;
            const relative = try std.fmt.allocPrint(a, "downloads/{x}", .{std.hash.Wyhash.hash(0, chapter.id)});
            const source = try std.fs.path.join(a, &.{ if (source_sd) engine.options.sd_dir.? else engine.options.dir, relative });
            const target = try std.fs.path.join(a, &.{ target_root, relative });
            try emptyDestination(io, target);
            required += try treeSize(a, io, source, cancel);
            const pages = try a.alloc([]const u8, chapter.pages.len);
            for (chapter.pages, pages) |page, *next| {
                if (std.mem.startsWith(u8, page, "sdcard/") != source_sd or !tachi.library.safePath(page)) return error.UnsupportedDownloadPath;
                const old = if (source_sd) page["sdcard/".len..] else page;
                if (!std.mem.startsWith(u8, old, relative) or old.len <= relative.len or old[relative.len] != '/') return error.UnsupportedDownloadPath;
                next.* = if (sd) try std.fmt.allocPrint(a, "sdcard/{s}", .{old}) else old;
            }
            try items.append(a, .{ .id = chapter.id, .source = source, .target = target, .source_sd = source_sd, .pages = pages });
        }
    }
    const space_path = try a.dupeSentinel(u8, target_root, 0);
    var available: u64 = 0;
    if (pm_storage_free(space_path, &available) != 0) {
        const parent = try a.dupeSentinel(u8, std.fs.path.dirname(target_root).?, 0);
        if (pm_storage_free(parent, &available) != 0) return error.StorageUnavailable;
    }
    if (required > available) return error.NoSpaceLeft;
    var moved: usize = 0;
    for (items.items) |item| {
        try Cancel.poll(cancel);
        const stage = try std.fmt.allocPrint(a, "{s}.moving", .{item.target});
        // A crash can leave an unpublished staging tree. Preflight verified
        // the authoritative source and an empty destination, so rebuild it.
        try Io.Dir.cwd().deleteTree(io, stage);
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(stage).?);
        try Io.Dir.cwd().createDir(io, stage, .default_dir);
        var committed = false;
        var promoted = false;
        const marker = try std.fmt.allocPrint(a, "{s}/downloads/{x}/destination.json", .{ engine.options.dir, std.hash.Wyhash.hash(0, item.id) });
        var marker_changed = false;
        defer if (!committed) {
            const previous = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(previous);
            Io.Dir.cwd().deleteTree(io, if (promoted) item.target else stage) catch {};
            if (marker_changed) {
                Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(marker).?) catch {};
                tachi.library.writeJsonAtomic(a, io, marker, .{ .sd_card = item.source_sd }) catch {};
            }
        };
        try copyTree(a, io, item.source, stage, cancel);
        try Cancel.poll(cancel);
        if (sd and !engine.sdAvailable()) return error.StorageUnavailable;
        try emptyDestination(io, item.target);
        // Copying is cancellable; publication and rollback form one short
        // protected transaction so task cancellation cannot strand the marker.
        const previous = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(previous);
        if (!sd) {
            marker_changed = true;
            Io.Dir.cwd().deleteFile(io, marker) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            Io.Dir.cwd().deleteDir(io, item.target) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        try Io.Dir.cwd().rename(stage, Io.Dir.cwd(), item.target, io);
        promoted = true;
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(marker).?);
        marker_changed = true;
        try tachi.library.writeJsonAtomic(a, io, marker, .{ .sd_card = sd });
        const Edit = struct {
            id: []const u8,
            pages: []const []const u8,
            fn apply(edit: @This(), alloc: std.mem.Allocator, current: tachi.library.Library) !?tachi.library.Library {
                if (edit.pages.len == 0) return null;
                return tachi.library.setPages(alloc, current, edit.id, edit.pages);
            }
        };
        _ = try engine.store.update(a, Edit{ .id = item.id, .pages = item.pages }, Edit.apply);
        committed = true;
        moved += 1;
        // The destination is authoritative now. Failure to reclaim old files is
        // harmless and reported for diagnosis rather than rolling back metadata.
        if (item.source_sd) {
            Io.Dir.cwd().deleteTree(io, item.source) catch |err| std.log.warn("Cannot remove moved chapter source {s}: {s}", .{ item.source, @errorName(err) });
        } else {
            // Keep the internal destination marker in place throughout cleanup.
            var source_dir = try Io.Dir.cwd().openDir(io, item.source, .{ .iterate = true });
            defer source_dir.close(io);
            var entries = source_dir.iterate();
            while (try entries.next(io)) |entry| {
                if (std.mem.eql(u8, entry.name, "destination.json")) continue;
                source_dir.deleteTree(io, entry.name) catch |err| std.log.warn("Cannot reclaim moved chapter file: {s}", .{@errorName(err)});
            }
        }
    }
    return moved;
}
