const std = @import("std");
const lib = @import("library.zig");
const local = @import("local.zig");
pub fn merge(gpa: std.mem.Allocator, old: lib.Library, manga: lib.Manga) !lib.Library {
    return update(gpa, old, manga, false);
}

/// Chapters omitted by a full source refresh survive only if downloaded.
pub fn refresh(gpa: std.mem.Allocator, old: lib.Library, manga: lib.Manga) !lib.Library {
    return update(gpa, old, manga, true);
}

fn update(gpa: std.mem.Allocator, old: lib.Library, manga: lib.Manga, prune: bool) !lib.Library {
    for (old.manga, 0..) |m, i| if (std.mem.eql(u8, m.id, manga.id)) {
        const titles = try gpa.dupe(lib.Manga, old.manga);
        var chapters: std.ArrayList(lib.Chapter) = .empty;
        for (m.chapters) |ch| {
            if (prune and ch.pages.len == 0) {
                for (manga.chapters) |current| {
                    if (std.mem.eql(u8, current.id, ch.id)) break;
                } else continue;
            }
            try chapters.append(gpa, ch);
        }
        for (manga.chapters) |ch| {
            for (chapters.items) |*existing| {
                if (std.mem.eql(u8, existing.id, ch.id)) {
                    const pages = existing.pages;
                    existing.* = ch;
                    if (ch.pages.len == 0) existing.pages = pages;
                    break;
                }
            } else try chapters.append(gpa, ch);
        }
        std.mem.sort(lib.Chapter, chapters.items, {}, struct {
            fn less(_: void, a: lib.Chapter, b: lib.Chapter) bool {
                if (a.remote) |ar| if (b.remote) |br| {
                    const an = ar.chapterNumber;
                    const bn = br.chapterNumber;
                    if (an >= 0 and bn >= 0 and an != bn) return an < bn;
                };
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
