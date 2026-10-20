//! The reader's UI state. The library itself is libtachi's.
const std = @import("std");
const Io = std.Io;
const tachi = @import("tachi");
pub const Library = tachi.library.Library;
pub const Manga = tachi.library.Manga;
pub const Chapter = tachi.library.Chapter;
pub const safePath = tachi.library.safePath;
/// Display preferences. `progress` is the pre-libtachi reading progress,
/// read once to migrate it into libtachi's reading state.
pub const Preferences = struct { rtl: bool = true, full_refresh: bool = true, progress: []const LegacyProgress = &.{} };
pub const LegacyProgress = struct { id: []const u8, page: usize = 0, completed: bool = false };

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
    /// Display preferences changed and should be saved.
    dirty: bool = false,
    /// The reader's page or a chapter's read state changed and should be
    /// recorded with libtachi.
    progress_changed: bool = false,
    query_text: []const u8 = "",
    return_screen: Screen = .library,
    /// Reading state changed since `library` was loaded, by chapter id; the
    /// session records each change with libtachi.
    reading: std.StringHashMapUnmanaged(ReadState) = .empty,
    pub const rows = 7;
    pub const ReadState = struct { page: u32, read: bool, started: bool };

    /// A chapter's reading state, including changes not yet reloaded.
    pub fn readState(self: *const Model, ch: Chapter) ReadState {
        if (self.reading.get(ch.id)) |state| return state;
        return .{ .page = ch.last_page_read, .read = ch.read, .started = ch.last_read != 0 };
    }

    /// Forgets the overlay; call when `library` is replaced, before the old
    /// library's memory goes (the overlay borrows its ids).
    pub fn clearReading(self: *Model) void {
        self.reading.clearAndFree(self.gpa);
    }

    /// Library titles only: titles taken out stay in libtachi's store for
    /// their history.
    pub fn matches(self: *const Model, manga: Manga) bool {
        if (!manga.favorite) return false;
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
    /// Marks the page now shown; the session records it with libtachi. A
    /// chapter becomes read on its last page.
    fn remember(self: *Model) !void {
        const ch = self.current() orelse return;
        if (ch.pages.len == 0) return;
        const old = self.readState(ch);
        const state: ReadState = .{ .page = @intCast(self.page), .read = old.read or self.page + 1 == ch.pages.len, .started = true };
        if (old.page == state.page and old.read == state.read and old.started) return;
        try self.reading.put(self.gpa, ch.id, state);
        self.progress_changed = true;
    }
    pub fn deinit(self: *Model) void {
        self.reading.deinit(self.gpa);
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
                self.page = @min(self.readState(chapters[i]).page, chapters[i].pages.len - 1);
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
