const std = @import("std");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Browser = @import("browser.zig").Browser;
const Image = @import("reader-image");
pub const Session = struct {
    model: *lib.Model,
    io: std.Io,
    root: []const u8,
    save_path: ?[]const u8 = null,
    image: ?Image = null,
    load_image: ?*const fn (*Session, []const u8) anyerror!void = null,
    status: []const u8 = "",
    activity: ?*const fn (bool) void = null,
    download_error: bool = false,
    download_canceled: bool = false,
    download_identity: ?struct { series: []const u8, chapter: []const u8 } = null,
    browser: Browser = .{},
    /// Owns `model.library` once loaded through the engine.
    library_arena: ?std.heap.ArenaAllocator = null,
    /// When the reader last recorded progress, for reading time.
    last_progress_ms: ?u64 = null,
    /// Owns the model's rows and category names.
    rows_arena: ?std.heap.ArenaAllocator = null,
    /// The chapter after the one being read, as libtachi's reader list
    /// orders and skips them: an index into the title's chapters.
    next_chapter: ?usize = null,
    fn clearDownloadIdentity(self: *Session) void {
        if (self.download_identity) |identity| {
            self.model.gpa.free(identity.series);
            self.model.gpa.free(identity.chapter);
        }
        self.download_identity = null;
    }
    /// Remembers the titles of the chapter a download request names.
    fn rememberDownload(self: *Session, chapter_id: []const u8) !void {
        for (self.model.library.manga) |m| for (m.chapters) |ch| {
            if (!std.mem.eql(u8, ch.id, chapter_id)) continue;
            const series = try self.model.gpa.dupe(u8, m.title);
            errdefer self.model.gpa.free(series);
            const chapter = try self.model.gpa.dupe(u8, ch.title);
            self.clearDownloadIdentity();
            self.download_identity = .{ .series = series, .chapter = chapter };
            return;
        };
    }
    /// The banner's headline already says failed or canceled; this is the detail.
    fn downloadDetail(self: *Session, job: *tachi.Job, failure: []const u8) ![]u8 {
        const done = job.pages_done.load(.acquire);
        const total = job.pages_total.load(.acquire);
        if (self.download_canceled) return std.fmt.allocPrint(self.model.gpa, "{d}/{d} pages saved", .{ done, total });
        return std.fmt.allocPrint(self.model.gpa, "{d}/{d} pages saved. {s}", .{ done, total, failure });
    }
    pub fn updateActivity(self: *Session) void {
        if (self.activity) |activity| activity(if (self.browser.busy) |job| !job.done.load(.acquire) else false);
    }
    pub fn start(self: *Session, request: tachi.engine.Request) void {
        defer self.updateActivity();
        if (request == .download and self.browser.busy == null) self.rememberDownload(request.download) catch {
            self.status = "Cannot start download: out of memory";
            self.download_error = true;
            self.download_canceled = false;
            return;
        };
        self.browser.start(request) catch |err| {
            self.download_error = request == .download;
            self.download_canceled = false;
            self.status = std.fmt.allocPrint(self.model.gpa, "{s}", .{@errorName(err)}) catch "Operation failed";
        };
    }
    pub fn poll(self: *Session) !void {
        defer self.updateActivity();
        const job = self.browser.busy orelse return;
        if (!job.done.load(.acquire)) return;
        job.join();
        self.browser.busy = null;
        errdefer job.deinit();
        if (job.result.library_changed) try self.reloadLibrary();
        self.download_error = job.failure != null and job.request == .download;
        self.download_canceled = self.download_error and std.mem.eql(u8, job.failure.?, "Canceled");
        if (self.download_error) try self.rememberDownload(job.request.download);
        self.status = if (job.failure) |failure|
            if (job.request == .download) try self.downloadDetail(job, failure) else try self.model.gpa.dupe(u8, failure)
        else
            try self.model.gpa.dupe(u8, job.result.message);
        if (job.failure != null) {
            if (self.browser.pending_chapter) |id| self.model.gpa.free(id);
            self.browser.pending_chapter = null;
            if (job.request == .browse and self.browser.titles != null) self.browser.page = self.browser.titles.?.request.browse.page;
            job.deinit();
            return;
        }
        if (job.request != .download) if (job.result.manga_id) |id| for (self.model.library.manga, 0..) |m, i| {
            if (std.mem.eql(u8, m.id, id)) {
                try self.act(.{ .open = i });
                break;
            }
        };
        if (job.request == .download) if (self.browser.pending_chapter) |id| {
            if (job.result.manga_id) |manga| for (self.model.library.manga, 0..) |m, i| {
                if (std.mem.eql(u8, m.id, manga)) self.model.manga = i;
            };
            for (self.model.library.manga[self.model.manga].chapters, 0..) |ch, i| {
                if (std.mem.eql(u8, ch.id, id)) {
                    try self.act(.{ .read = i });
                    break;
                }
            }
            self.model.gpa.free(id);
            self.browser.pending_chapter = null;
        };
        const slot: ?*?*tachi.Job = switch (job.request) {
            .sources, .install, .install_file, .uninstall => &self.browser.sources,
            .extensions => &self.browser.extensions,
            .browse => &self.browser.titles,
            .preferences, .set_preference => &self.browser.preferences,
            else => null,
        };
        if (slot) |target| {
            if (target.*) |old| old.deinit();
            target.* = job;
        } else job.deinit();
    }
    pub fn reloadLibrary(self: *Session) !void {
        const engine = self.browser.engine orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
        errdefer arena.deinit();
        self.model.library = try engine.loadLibrary(arena.allocator());
        self.model.clearReading();
        if (self.library_arena) |*old| old.deinit();
        self.library_arena = arena;
        try self.refreshRows();
    }

    /// Lays out the library and chapter lists as libtachi's views do: the
    /// current category's titles, filtered, sorted and searched, and the
    /// current title's chapters by its chapter flags.
    pub fn refreshRows(self: *Session) !void {
        const model = self.model;
        var arena: std.heap.ArenaAllocator = .init(model.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const settings: tachi.settings.Settings = if (self.browser.engine) |engine| try engine.loadSettings(a) else .{};
        const groups = try tachi.views.libraryView(a, model.library, try tachi.views.libraryOptions(a, model.library, settings, model.query_text, 0));
        const names = try a.alloc([]const u8, groups.len);
        for (groups, names) |group, *name| name.* = if (group.category.id == 0) "Default" else group.category.name;
        if (model.category >= groups.len) model.category = 0;
        var titles: std.ArrayList(usize) = .empty;
        if (groups.len > 0) for (groups[model.category].entries) |entry| {
            try titles.append(a, (@intFromPtr(entry.manga) - @intFromPtr(model.library.manga.ptr)) / @sizeOf(lib.Manga));
        };
        var chapters: ?[]const usize = null;
        if (model.manga < model.library.manga.len) {
            const manga = model.library.manga[model.manga];
            var index: std.StringHashMapUnmanaged(usize) = .empty;
            for (manga.chapters, 0..) |ch, i| try index.put(a, ch.id, i);
            const shown = try tachi.views.chapterList(a, manga, settings.library.downloaded_only);
            const rows = try a.alloc(usize, shown.len);
            for (shown, rows) |ch, *row| row.* = index.get(ch.id).?;
            chapters = rows;
        }
        model.title_rows = titles.items;
        model.chapter_rows = chapters;
        model.categories = names;
        if (self.rows_arena) |*old| old.deinit();
        self.rows_arena = arena;
    }
    /// Moves reading progress from the pre-libtachi preferences file into
    /// libtachi's reading state, once.
    pub fn migrateProgress(self: *Session) !void {
        const engine = self.browser.engine orelse return;
        const legacy = self.model.prefs.progress;
        if (legacy.len == 0) return;
        const progress = try self.model.gpa.alloc(tachi.library.Progress, legacy.len);
        defer self.model.gpa.free(progress);
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        for (legacy, progress) |old, *new| new.* = .{ .chapter_id = old.id, .page = @intCast(old.page), .read = old.completed, .now = @intCast(now) };
        try engine.setProgressMany(progress);
        self.model.prefs.progress = &.{};
        self.model.dirty = true;
        try self.reloadLibrary();
    }
    pub fn deinit(self: *Session) void {
        self.clearDownloadIdentity();
        self.browser.deinit(self.model.gpa);
        if (self.activity) |activity| activity(false);
        if (self.library_arena) |*arena| arena.deinit();
        if (self.rows_arena) |*arena| arena.deinit();
    }
    pub fn act(self: *Session, action: lib.Action) !void {
        const before = self.model.current();
        const old_page = self.model.page;
        const old_screen = self.model.screen;
        const old_manga = self.model.manga;
        try self.model.dispatch(action);
        const lists = self.model.screen == .library or self.model.screen == .chapters;
        if (lists and (action == .search or action == .category or old_screen != self.model.screen or old_manga != self.model.manga or self.model.title_rows == null)) try self.refreshRows();
        if (self.model.screen == .reader and (old_screen != .reader or old_page != self.model.page or before == null or !std.mem.eql(u8, before.?.id, self.model.current().?.id))) {
            self.status = "";
            self.download_error = false;
            self.clearDownloadIdentity();
            // Reading needs no extensions: let a worker give its memory back.
            if (self.browser.busy == null) if (self.browser.engine) |engine| engine.backend.release();
            if (self.load_image) |load| {
                const path = self.model.current().?.pages[self.model.page];
                load(self, path) catch |err| {
                    self.image = null;
                    self.status = try std.fmt.allocPrint(self.model.gpa, "Cannot open page: {s}", .{@errorName(err)});
                };
            }
        }
        if (self.model.screen == .reader and (old_screen != .reader or before == null or !std.mem.eql(u8, before.?.id, self.model.current().?.id))) self.findNextChapter();
        if (self.model.screen != .reader) {
            self.last_progress_ms = null;
            self.next_chapter = null;
        }
        if (self.model.progress_changed) self.recordProgress();
        // Leaving the reader deletes what finished chapters queued for deletion.
        if (old_screen == .reader and self.model.screen != .reader) if (self.browser.engine) |engine| engine.leaveReader() catch |err| {
            self.status = try std.fmt.allocPrint(self.model.gpa, "Downloads not deleted: {s}", .{@errorName(err)});
        };
        if (self.model.dirty) if (self.save_path) |path| {
            lib.writeJson(self.model.gpa, self.io, path, self.model.prefs) catch |err| {
                self.status = try std.fmt.allocPrint(self.model.gpa, "Settings not saved: {s}", .{@errorName(err)});
                return;
            };
            self.model.dirty = false;
        };
    }
    /// Tells libtachi which page is shown, with the time spent since the
    /// last page (at most five minutes, so an idle reader does not count).
    /// libtachi marks the chapter read on its last page and does the rest.
    fn recordProgress(self: *Session) void {
        self.model.progress_changed = false;
        const engine = self.browser.engine orelse return;
        const ch = self.model.current() orelse return;
        const state = self.model.readState(ch);
        const now: u64 = @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds());
        const read_ms: i64 = if (self.last_progress_ms) |last| @intCast(@min(now - last, 5 * 60 * 1000)) else 0;
        self.last_progress_ms = now;
        engine.pageShown(.{ .chapter_id = ch.id, .page = state.page, .pages = @intCast(ch.pages.len), .read_ms = read_ms }) catch |err| {
            self.status = std.fmt.allocPrint(self.model.gpa, "Progress not saved: {s}", .{@errorName(err)}) catch "Progress not saved";
        };
    }

    fn findNextChapter(self: *Session) void {
        self.next_chapter = null;
        const engine = self.browser.engine orelse return;
        const ch = self.model.current() orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
        defer arena.deinit();
        const list = engine.readerChapters(arena.allocator(), ch.id) catch return;
        const next = list.next() orelse return;
        for (self.model.library.manga[self.model.manga].chapters, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate.id, next.id)) self.next_chapter = i;
        }
    }
};
