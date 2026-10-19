const std = @import("std");
const Io = std.Io;
const models = @import("source_models.zig");
pub const Chapter = struct { id: []const u8, title: []const u8, pages: []const []const u8 = &.{}, remote: ?models.Chapter = null };
pub const Manga = struct { id: []const u8, title: []const u8, author: []const u8 = "", description: []const u8 = "", chapters: []const Chapter = &.{}, source_id: ?i64 = null, remote: ?models.Manga = null };
pub const Library = struct { version: u32 = 1, manga: []const Manga = &.{} };
pub const Entry = struct { id: []const u8, page: usize = 0, completed: bool = false };
pub const Preferences = struct { rtl: bool = true, full_refresh: bool = true, progress: []const Entry = &.{} };

pub fn safePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..") or part.len == 0) return false;
    return true;
}
pub fn validate(lib: Library) !void {
    if (lib.version != 1) return error.UnsupportedLibraryVersion;
    for (lib.manga, 0..) |m, mi| {
        if (m.id.len == 0 or m.title.len == 0) return error.InvalidManga;
        for (lib.manga[0..mi]) |prior| if (std.mem.eql(u8, prior.id, m.id)) return error.DuplicateManga;
        for (m.chapters, 0..) |ch, ci| {
            if (ch.id.len == 0) return error.InvalidChapter;
            for (lib.manga[0 .. mi + 1], 0..) |prior_m, pmi| {
                const end = if (pmi == mi) ci else prior_m.chapters.len;
                for (prior_m.chapters[0..end]) |prior| if (std.mem.eql(u8, prior.id, ch.id)) return error.DuplicateChapter;
            }
            for (ch.pages) |path| if (!safePath(path)) return error.UnsafePagePath;
        }
    }
}
pub fn readJson(comptime T: type, gpa: std.mem.Allocator, io: Io, path: []const u8) !std.json.Parsed(T) {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);
    return std.json.parseFromSlice(T, gpa, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}
pub fn writeJson(gpa: std.mem.Allocator, io: Io, path: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    defer gpa.free(bytes);
    const temp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(temp);
    errdefer Io.Dir.cwd().deleteFile(io, temp) catch {};
    {
        const file = try Io.Dir.cwd().createFile(io, temp, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try Io.Dir.cwd().rename(temp, Io.Dir.cwd(), path, io);
}

pub const Screen = enum { library, chapters, reader, settings, sources, extensions, catalog, source_settings };
pub const Action = union(enum) { back, search: []const u8, open: usize, read: usize, turn: i32, next_chapter, list_page: i32, settings, help, rtl, refresh };
pub const Model = struct {
    gpa: std.mem.Allocator,
    library: Library = .{},
    prefs: Preferences = .{},
    screen: Screen = .library,
    manga: usize = 0,
    chapter: usize = 0,
    page: usize = 0,
    offset: usize = 0,
    dirty: bool = false,
    query_text: []const u8 = "",
    progress_owned: bool = false,
    return_screen: Screen = .library,
    pub const rows = 7;

    pub fn matches(self: *const Model, manga: Manga) bool {
        return self.query_text.len == 0 or std.ascii.findIgnoreCase(manga.title, self.query_text) != null or std.ascii.findIgnoreCase(manga.author, self.query_text) != null;
    }
    pub fn titleCount(self: *const Model) usize {
        var count: usize = 0;
        for (self.library.manga) |m| if (self.matches(m)) {
            count += 1;
        };
        return count;
    }
    pub fn titleIndex(self: *const Model, row: usize) usize {
        var count: usize = 0;
        for (self.library.manga, 0..) |m, i| if (self.matches(m)) {
            if (count == row) return i;
            count += 1;
        };
        unreachable;
    }
    pub fn current(self: *const Model) ?Chapter {
        if (self.manga >= self.library.manga.len) return null;
        const chapters = self.library.manga[self.manga].chapters;
        if (self.chapter >= chapters.len) return null;
        return chapters[self.chapter];
    }
    pub fn progress(self: *const Model, id: []const u8) ?Entry {
        for (self.prefs.progress) |p| if (std.mem.eql(u8, p.id, id)) return p;
        return null;
    }
    fn remember(self: *Model) !void {
        const ch = self.current() orelse return;
        if (ch.pages.len == 0) return;
        const entry: Entry = .{ .id = ch.id, .page = self.page, .completed = self.page + 1 == ch.pages.len };
        if (!self.progress_owned) {
            const copy = try self.gpa.dupe(Entry, self.prefs.progress);
            var copied: usize = 0;
            errdefer {
                for (copy[0..copied]) |p| self.gpa.free(p.id);
                self.gpa.free(copy);
            }
            for (copy) |*p| {
                p.id = try self.gpa.dupe(u8, p.id);
                copied += 1;
            }
            self.prefs.progress = copy;
            self.progress_owned = true;
        }
        const entries = @constCast(self.prefs.progress);
        for (entries) |*p| if (std.mem.eql(u8, p.id, ch.id)) {
            const completed = p.completed;
            if (p.page == entry.page and (p.completed or !entry.completed)) return;
            const owned_id = p.id;
            p.* = entry;
            p.id = owned_id;
            p.completed = p.completed or completed;
            self.dirty = true;
            return;
        };
        const id = try self.gpa.dupe(u8, ch.id);
        errdefer self.gpa.free(id);
        const appended = try self.gpa.realloc(entries, entries.len + 1);
        appended[appended.len - 1] = entry;
        appended[appended.len - 1].id = id;
        self.prefs.progress = appended;
        self.dirty = true;
    }
    pub fn deinit(self: *Model) void {
        if (self.progress_owned) {
            for (self.prefs.progress) |p| self.gpa.free(p.id);
            self.gpa.free(self.prefs.progress);
        }
        if (self.query_text.len > 0) self.gpa.free(self.query_text);
    }
    pub fn dispatch(self: *Model, action: Action) !void {
        switch (action) {
            .search => |query| {
                const copy = if (query.len == 0) "" else try self.gpa.dupe(u8, query);
                if (self.query_text.len > 0) self.gpa.free(self.query_text);
                self.query_text = copy;
                self.offset = 0;
            },
            .open => |i| if (i < self.library.manga.len) {
                self.manga = i;
                self.offset = 0;
                self.screen = .chapters;
            },
            .read => |i| {
                if (self.manga >= self.library.manga.len) return;
                const chapters = self.library.manga[self.manga].chapters;
                if (i >= chapters.len or chapters[i].pages.len == 0) return;
                self.chapter = i;
                self.page = @min(if (self.progress(chapters[i].id)) |p| p.page else 0, chapters[i].pages.len - 1);
                self.screen = .reader;
                try self.remember();
            },
            .turn => |delta| {
                if (self.screen != .reader) return;
                const ch = self.current() orelse return;
                if (ch.pages.len == 0) return;
                const p: i64 = @as(i64, @intCast(self.page)) + delta;
                self.page = @intCast(std.math.clamp(p, 0, @as(i64, @intCast(ch.pages.len - 1))));
                try self.remember();
            },
            .next_chapter => {
                if (self.screen != .reader) return;
                const chapters = self.library.manga[self.manga].chapters;
                if (self.chapter + 1 < chapters.len) try self.dispatch(.{ .read = self.chapter + 1 });
            },
            .back => switch (self.screen) {
                .reader => {
                    self.screen = .chapters;
                    self.offset = self.chapter / rows * rows;
                },
                .settings => self.screen = self.return_screen,
                .extensions, .catalog, .source_settings => {
                    self.screen = .sources;
                    self.offset = 0;
                },
                .sources => {
                    self.screen = .library;
                    self.offset = 0;
                },
                else => {
                    self.screen = .library;
                    self.offset = 0;
                },
            },
            .list_page => |delta| {
                const count = switch (self.screen) {
                    .library => self.titleCount(),
                    .chapters => self.library.manga[self.manga].chapters.len,
                    else => return,
                };
                if (count == 0) return;
                const next: i64 = @as(i64, @intCast(self.offset)) + @as(i64, delta) * rows;
                self.offset = @intCast(std.math.clamp(next, 0, @as(i64, @intCast((count - 1) / rows * rows))));
            },
            .settings => {
                self.return_screen = self.screen;
                self.screen = .settings;
            },
            .help => {
                self.screen = .sources;
                self.offset = 0;
            },
            .rtl => {
                self.prefs.rtl = !self.prefs.rtl;
                self.dirty = true;
            },
            .refresh => {
                self.prefs.full_refresh = !self.prefs.full_refresh;
                self.dirty = true;
            },
        }
    }
};
