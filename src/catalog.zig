const std = @import("std");
const lib = @import("library.zig");
const local = @import("local.zig");
pub fn merge(gpa: std.mem.Allocator, old: lib.Library, manga: lib.Manga) !lib.Library {
    for (old.manga, 0..) |m, i| if (std.mem.eql(u8, m.id, manga.id)) {
        const titles = try gpa.dupe(lib.Manga, old.manga);
        var chapters: std.ArrayList(lib.Chapter) = .empty;
        try chapters.appendSlice(gpa, m.chapters);
        for (manga.chapters) |ch| {
            var found = false;
            for (chapters.items) |*existing| if (std.mem.eql(u8, existing.id, ch.id)) {
                const pages = existing.pages;
                existing.* = ch;
                if (ch.pages.len == 0) existing.pages = pages;
                found = true;
                break;
            };
            if (!found) try chapters.append(gpa, ch);
        }
        std.mem.sort(lib.Chapter, chapters.items, {}, struct {
            fn less(_: void, a: lib.Chapter, b: lib.Chapter) bool {
                if (a.remote != null and b.remote != null) {
                    const an = a.remote.?.chapterNumber;
                    const bn = b.remote.?.chapterNumber;
                    if (an >= 0 and bn >= 0 and an != bn) return an < bn;
                }
                return local.naturalLess({}, a.title, b.title);
            }
        }.less);
        titles[i] = manga;
        titles[i].chapters = chapters.items;
        return .{ .manga = titles };
    };
    const titles = try gpa.alloc(lib.Manga, old.manga.len + 1);
    @memcpy(titles[0..old.manga.len], old.manga);
    titles[old.manga.len] = manga;
    return .{ .manga = titles };
}
