const std = @import("std");
const Io = std.Io;
const lib = @import("library.zig");
// Compare numeric runs so Chapter 2 and page 9 precede Chapter 10/page 10.
pub fn naturalLess(_: void, a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var ai = i;
            var bj = j;
            while (ai < a.len and a[ai] == '0') : (ai += 1) {}
            while (bj < b.len and b[bj] == '0') : (bj += 1) {}
            var ae = ai;
            var be = bj;
            while (ae < a.len and std.ascii.isDigit(a[ae])) : (ae += 1) {}
            while (be < b.len and std.ascii.isDigit(b[be])) : (be += 1) {}
            if (ae - ai != be - bj) return ae - ai < be - bj;
            const order = std.mem.order(u8, a[ai..ae], b[bj..be]);
            if (order != .eq) return order == .lt;
            i = ae;
            j = be;
        } else {
            const ac = std.ascii.toLower(a[i]);
            const bc = std.ascii.toLower(b[j]);
            if (ac != bc) return ac < bc;
            i += 1;
            j += 1;
        }
    }
    if (a.len - i != b.len - j) return a.len - i < b.len - j;
    return std.mem.lessThan(u8, a, b);
}
fn names(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, directories: bool) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.name.len == 0 or e.name[0] == '.' or std.mem.eql(u8, e.name, "downloads")) continue;
        if (directories) {
            if (e.kind != .directory) continue;
        } else {
            if (e.kind != .file) continue;
            const ext = std.fs.path.extension(e.name);
            if (!std.ascii.eqlIgnoreCase(ext, ".jpg") and !std.ascii.eqlIgnoreCase(ext, ".jpeg") and !std.ascii.eqlIgnoreCase(ext, ".png")) continue;
        }
        try result.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, result.items, {}, naturalLess);
    return result.items;
}
pub fn scan(gpa: std.mem.Allocator, io: Io, root: []const u8) !lib.Library {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var titles: std.ArrayList(lib.Manga) = .empty;
    for (try names(gpa, io, dir, true)) |title| {
        var md = try dir.openDir(io, title, .{ .iterate = true });
        defer md.close(io);
        var chapters: std.ArrayList(lib.Chapter) = .empty;
        for (try names(gpa, io, md, true)) |chapter| {
            var cd = try md.openDir(io, chapter, .{ .iterate = true });
            defer cd.close(io);
            var pages: std.ArrayList([]const u8) = .empty;
            for (try names(gpa, io, cd, false)) |page| try pages.append(gpa, try std.fs.path.join(gpa, &.{ title, chapter, page }));
            if (pages.items.len == 0) continue;
            try chapters.append(gpa, .{ .id = try std.fmt.allocPrint(gpa, "local:{s}/{s}", .{ title, chapter }), .title = chapter, .pages = pages.items });
        }
        if (chapters.items.len == 0) continue;
        try titles.append(gpa, .{ .id = try std.fmt.allocPrint(gpa, "local:{s}", .{title}), .title = title, .chapters = chapters.items });
    }
    return .{ .manga = titles.items };
}
