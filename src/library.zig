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

pub const Screen = enum { library, chapters, reader, settings, sources, extensions, catalog, source_settings, updates, history, queue, chapter_menu, title_menu, engine_settings, backup, categories, global_search, languages };
/// libtachi settings the settings screen changes.
pub const Setting = enum { skip_completed, skip_unread, skip_not_started, skip_not_due, update_details, download_new, delete_marked_read, delete_bookmarked, delete_after_reading, download_ahead, skip_read, skip_filtered, skip_duplicates, incognito, downloaded_only, sort_mode, sort_ascending };
pub const Pick = struct { manga: usize, chapter: usize };
pub const Action = union(enum) { back, search: []const u8, open: usize, read: usize, open_chapter: Pick, turn: i32, next_chapter, list_page: i32, category: i32, feed: Screen, menu: usize, settings, help, rtl, refresh };
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
    /// The titles libtachi's library view shows in the current category,
    /// and the current title's chapters as its chapter list shows them, as
    /// indexes into `library`; the session fills them in. Null shows
    /// everything in stored order.
    title_rows: ?[]const usize = null,
    chapter_rows: ?[]const usize = null,
    /// Category names in libtachi's order, and the one shown.
    categories: []const []const u8 = &.{},
    category: usize = 0,
    /// Rows in the updates, history or queue list the session shows.
    feed_count: usize = 0,
    /// The chapter the chapter menu is for.
    menu_chapter: usize = 0,
    /// A chapter being read online, and its pages in libtachi's chapter
    /// cache (a failed page's path is empty).
    online_chapter: ?[]const u8 = null,
    online_pages: []const []const u8 = &.{},
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

    pub fn titleCount(self: *const Model) usize {
        return if (self.title_rows) |list| list.len else self.library.manga.len;
    }
    pub fn titleIndex(self: *const Model, row: usize) usize {
        return if (self.title_rows) |list| list[row] else row;
    }
    pub fn chapterCount(self: *const Model) usize {
        if (self.chapter_rows) |list| return list.len;
        return if (self.manga < self.library.manga.len) self.library.manga[self.manga].chapters.len else 0;
    }
    pub fn chapterIndex(self: *const Model, row: usize) usize {
        return if (self.chapter_rows) |list| list[row] else row;
    }
    /// The row showing chapter `index`.
    fn chapterRow(self: *const Model, index: usize) usize {
        const list = self.chapter_rows orelse return index;
        return std.mem.indexOfScalar(usize, list, index) orelse 0;
    }
    pub fn current(self: *const Model) ?Chapter {
        if (self.manga >= self.library.manga.len) return null;
        const chapters = self.library.manga[self.manga].chapters;
        if (self.chapter >= chapters.len) return null;
        return self.withPages(chapters[self.chapter]);
    }
    /// The chapter with its online pages if it is being read online.
    fn withPages(self: *const Model, ch: Chapter) Chapter {
        var copy = ch;
        if (ch.pages.len == 0) if (self.online_chapter) |id| if (std.mem.eql(u8, id, ch.id)) {
            copy.pages = self.online_pages;
        };
        return copy;
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
                if (i >= chapters.len) return;
                const ch = self.withPages(chapters[i]);
                if (ch.pages.len == 0) return;
                self.chapter = i;
                self.page = @min(self.readState(ch).page, ch.pages.len - 1);
                self.screen = .reader;
                try self.remember();
            },
            .open_chapter => |pick| if (pick.manga < self.library.manga.len) {
                self.manga = pick.manga;
                try self.dispatch(.{ .read = pick.chapter });
            },
            .feed => |screen| {
                self.screen = screen;
                self.offset = 0;
            },
            .menu => |i| switch (self.screen) {
                .library => if (i < self.library.manga.len) {
                    self.manga = i;
                    self.screen = .title_menu;
                },
                .chapters => {
                    self.menu_chapter = i;
                    self.screen = .chapter_menu;
                },
                else => {},
            },
            .turn => |delta| {
                if (self.screen != .reader) return;
                const ch = self.current() orelse return;
                if (ch.pages.len == 0) return;
                const p: i64 = @as(i64, @intCast(self.page)) + delta;
                self.page = @intCast(std.math.clamp(p, 0, @as(i64, @intCast(ch.pages.len - 1))));
                try self.remember();
            },
            // libtachi picks the next chapter; the UI turns this into `read`.
            .next_chapter => {},
            .back => switch (self.screen) {
                .reader => {
                    self.screen = .chapters;
                    self.offset = self.chapterRow(self.chapter) / rows * rows;
                },
                .settings => self.screen = self.return_screen,
                .chapter_menu => self.screen = .chapters,
                .engine_settings, .backup, .categories => {
                    self.screen = .settings;
                    self.offset = 0;
                },
                .extensions, .catalog, .source_settings, .global_search, .languages => {
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
                    .chapters => self.chapterCount(),
                    .updates, .history, .queue, .backup => self.feed_count,
                    .categories => self.library.categories.len,
                    .engine_settings => std.enums.values(Setting).len,
                    else => return,
                };
                if (count == 0) return;
                const next: i64 = @as(i64, @intCast(self.offset)) + @as(i64, delta) * rows;
                self.offset = @intCast(std.math.clamp(next, 0, @as(i64, @intCast((count - 1) / rows * rows))));
            },
            .category => |delta| {
                if (self.categories.len == 0) return;
                const next: i64 = @as(i64, @intCast(self.category)) + delta;
                self.category = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(self.categories.len - 1))));
                self.offset = 0;
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
