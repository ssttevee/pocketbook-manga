const std = @import("std");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Browser = @import("browser.zig").Browser;
const Image = @import("reader-image");
/// A row of the updates, history or download queue screens.
pub const FeedRow = struct { pick: lib.Pick, title: []const u8, detail: []const u8 };

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
    /// Owns the model's online chapter and pages.
    online_arena: ?std.heap.ArenaAllocator = null,
    /// libtachi's library statistics, when shown.
    stats: tachi.views.Stats = .{},
    /// A title about to be added that libtachi thinks the library already
    /// has, with the titles it matched.
    pending_add: ?struct { source: i64, manga: tachi.models.Manga, matches: []const []const u8 } = null,
    pending_arena: ?std.heap.ArenaAllocator = null,
    /// libtachi's settings as the settings screen shows them.
    settings: tachi.settings.Settings = .{},
    settings_arena: ?std.heap.ArenaAllocator = null,
    /// The category the library shows, for sorting it.
    category_id: u32 = 0,
    /// The updates, history or queue list being shown, and what owns it.
    feed: []const FeedRow = &.{},
    feed_arena: ?std.heap.ArenaAllocator = null,
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
        if (self.model.screen == .queue and self.browser.busy == null) try self.refreshFeed();
        const job = self.browser.busy orelse return;
        if (!job.done.load(.acquire)) return;
        job.join();
        self.browser.busy = null;
        errdefer job.deinit();
        if (job.result.library_changed) try self.reloadLibrary();
        if (self.model.screen == .backup) try self.refreshBackups();
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
        if (job.request == .read) {
            try self.openOnline(job.request.read.chapter, job.result.pages);
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
            .global_search => &self.browser.global,
            else => null,
        };
        if (slot) |target| {
            if (target.*) |old| old.deinit();
            target.* = job;
            if (target == &self.browser.sources) try self.browser.refreshSourceRows(self.model.gpa);
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

    /// Adds a browsed title, unless libtachi finds it may already be in
    /// the library: then asks first, as Mihon does.
    pub fn addTitle(self: *Session, source: i64, manga: tachi.models.Manga) !void {
        const engine = self.browser.engine orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const candidate: tachi.library.Manga = .{ .id = try tachi.library.mangaId(a, source, manga.url), .title = manga.title };
        const found = try engine.duplicates(a, candidate);
        if (found.len == 0) {
            arena.deinit();
            self.start(.{ .add = .{ .source = source, .manga = manga } });
            return;
        }
        const names = try a.alloc([]const u8, found.len);
        for (found, names) |m, *name| name.* = try a.dupe(u8, m.title);
        const json = try std.json.Stringify.valueAlloc(a, manga, .{});
        const copy = try std.json.parseFromSliceLeaky(tachi.models.Manga, a, json, tachi.models.parse_options);
        if (self.pending_arena) |*old| old.deinit();
        self.pending_arena = arena;
        self.pending_add = .{ .source = source, .manga = copy, .matches = names };
        self.model.screen = .duplicate;
    }

    /// Answers the duplicate question: add anyway, or not.
    pub fn confirmAdd(self: *Session, add: bool) void {
        const pending = self.pending_add orelse return;
        self.model.screen = .catalog;
        if (add) self.start(.{ .add = .{ .source = pending.source, .manga = pending.manga } });
        self.pending_add = null;
    }

    /// Opens a chapter read online with the pages libtachi loaded.
    fn openOnline(self: *Session, chapter_id: []const u8, pages: []const []const u8) !void {
        const model = self.model;
        var arena: std.heap.ArenaAllocator = .init(model.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const copies = try a.alloc([]const u8, pages.len);
        for (pages, copies) |page, *copy| copy.* = try a.dupe(u8, page);
        model.online_chapter = try a.dupe(u8, chapter_id);
        model.online_pages = copies;
        if (self.online_arena) |*old| old.deinit();
        self.online_arena = arena;
        for (model.library.manga[model.manga].chapters, 0..) |ch, i| if (std.mem.eql(u8, ch.id, chapter_id)) {
            try self.act(.{ .read = i });
            return;
        };
    }

    /// Fills the updates, history or download queue list from libtachi.
    pub fn refreshFeed(self: *Session) !void {
        const model = self.model;
        var arena: std.heap.ArenaAllocator = .init(model.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const settings: tachi.settings.Settings = if (self.browser.engine) |engine| try engine.loadSettings(a) else .{};
        var rows: std.ArrayList(FeedRow) = .empty;
        // Rows map back to the model's library by chapter id.
        var picks: std.StringHashMapUnmanaged(lib.Pick) = .empty;
        for (model.library.manga, 0..) |m, mi| for (m.chapters, 0..) |ch, ci| try picks.put(a, ch.id, .{ .manga = mi, .chapter = ci });
        switch (model.screen) {
            .updates, .history => {
                const now = std.Io.Clock.real.now(self.io).toMilliseconds();
                const u = settings.updates;
                // The store has reading state the model hasn't reloaded.
                const library = if (self.browser.engine) |engine| try engine.loadLibrary(a) else model.library;
                const items = if (model.screen == .updates) try tachi.views.updates(a, library, .{
                    .downloaded = u.downloaded,
                    .unread = u.unread,
                    .started = u.started,
                    .bookmarked = u.bookmarked,
                    .hide_excluded_scanlators = u.hide_excluded_scanlators,
                    .categories = u.categories,
                    .exclude_categories = u.exclude_categories,
                    .downloaded_only = settings.library.downloaded_only,
                    .now = @intCast(now),
                }) else try tachi.views.history(a, library, "");
                for (items) |item| {
                    const pick = picks.get(item.chapter.id) orelse continue;
                    const ch = item.chapter;
                    try rows.append(a, .{ .pick = pick, .title = item.manga.title, .detail = try std.fmt.allocPrint(a, "{s}  /  {s}", .{ ch.title, if (ch.read) "Read" else if (ch.last_read != 0) "Reading" else "Unread" }) });
                }
                if (model.screen == .updates) if (self.browser.engine) |engine| engine.markUpdatesSeen() catch {};
            },
            .queue => if (self.browser.engine) |engine| {
                for (try engine.queue.snapshot(engine, a)) |entry| {
                    const pick = picks.get(entry.chapter_id) orelse continue;
                    const m = model.library.manga[pick.manga];
                    const detail = switch (entry.status) {
                        .queued => "Queued",
                        .downloading => try std.fmt.allocPrint(a, "Downloading {d}/{d}", .{ entry.pages_done, entry.pages_total }),
                        .failed => try std.fmt.allocPrint(a, "Failed: {s}", .{entry.failure orelse "error"}),
                    };
                    try rows.append(a, .{ .pick = pick, .title = m.title, .detail = try std.fmt.allocPrint(a, "{s}  /  {s}", .{ m.chapters[pick.chapter].title, detail }) });
                }
            },
            else => {},
        }
        model.feed_count = rows.items.len;
        if (model.offset >= rows.items.len) model.offset = 0;
        self.feed = rows.items;
        if (self.feed_arena) |*old| old.deinit();
        self.feed_arena = arena;
    }

    pub const Edit = union(enum) { mark_read, mark_unread, mark_previous, bookmark, unbookmark, download, delete_download, title_read, title_unread, remove_title, toggle_category: u32, migrate, read_online };

    /// Searches every enabled source, or only pinned ones if the settings
    /// say so and some are pinned.
    pub fn globalSearch(self: *Session, query: []const u8) !void {
        const engine = self.browser.engine orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
        defer arena.deinit();
        const s = try engine.loadSettings(arena.allocator());
        self.model.screen = .global_search;
        self.browser.offset = 0;
        self.start(.{ .global_search = .{ .query = query, .pinned_only = s.browse.search_pinned_only and s.browse.pinned_sources.len > 0 } });
    }

    /// Applies a chapter or title menu choice through libtachi, then shows
    /// the list again.
    pub fn edit(self: *Session, choice: Edit) !void {
        const engine = self.browser.engine orelse return;
        const model = self.model;
        if (model.manga >= model.library.manga.len) return;
        const manga = model.library.manga[model.manga];
        const chapter_id: []const u8 = if (model.menu_chapter < manga.chapters.len) manga.chapters[model.menu_chapter].id else "";
        const one: []const []const u8 = &.{chapter_id};
        var back: lib.Screen = .chapters;
        switch (choice) {
            .mark_read => _ = try engine.markRead(one, true),
            .mark_unread => _ = try engine.markRead(one, false),
            .mark_previous => _ = try engine.markPreviousRead(chapter_id),
            .bookmark => _ = try engine.setBookmark(one, true),
            .unbookmark => _ = try engine.setBookmark(one, false),
            .download => _ = try engine.queue.enqueue(engine, one, true),
            .delete_download => if (try engine.deleteDownloads(one) == 0) {
                self.status = "Kept by the download deletion settings";
            },
            .title_read, .title_unread => {
                _ = try engine.markTitleRead(manga.id, choice == .title_read);
                back = .library;
            },
            .remove_title => {
                try engine.setFavorite(manga.id, false);
                back = .library;
            },
            .read_online => {
                // libtachi loads it into its chapter cache; poll opens it.
                model.screen = .chapters;
                self.start(.{ .read = .{ .chapter = chapter_id, .page = model.readState(manga.chapters[model.menu_chapter]).page } });
                return;
            },
            .migrate => {
                // Find the title elsewhere; picking a result migrates it.
                const id = try model.gpa.dupe(u8, manga.id);
                if (self.browser.migrate_from) |old| model.gpa.free(old);
                self.browser.migrate_from = id;
                try self.globalSearch(manga.title);
                return;
            },
            .toggle_category => |id| {
                var categories: std.ArrayList(u32) = .empty;
                defer categories.deinit(model.gpa);
                var had = false;
                for (manga.categories) |c| {
                    if (c == id) had = true else try categories.append(model.gpa, c);
                }
                if (!had) try categories.append(model.gpa, id);
                try engine.setCategories(&.{manga.id}, categories.items);
                back = .title_menu;
            },
        }
        try self.reloadLibrary();
        model.screen = back;
        try self.refreshRows();
    }

    /// Where backups are written and found, and where a Mihon downloads
    /// folder is exchanged.
    pub fn backupDir(self: *const Session, a: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(a, &.{ self.root, "backups" });
    }
    pub fn mihonDownloadsDir(self: *const Session, a: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(a, &.{ self.root, "mihon-downloads" });
    }

    /// Lists the backups in `backupDir`, newest name first, as feed rows.
    pub fn refreshBackups(self: *Session) !void {
        var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var rows: std.ArrayList(FeedRow) = .empty;
        if (std.Io.Dir.cwd().openDir(self.io, try self.backupDir(a), .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(self.io);
            var it = d.iterate();
            while (try it.next(self.io)) |e| {
                if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".tachibk")) continue;
                try rows.append(a, .{ .pick = .{ .manga = 0, .chapter = 0 }, .title = try a.dupe(u8, e.name), .detail = "Tap to restore" });
            }
        } else |_| {}
        std.mem.sort(FeedRow, rows.items, {}, struct {
            fn less(_: void, x: FeedRow, y: FeedRow) bool {
                return std.mem.order(u8, x.title, y.title) == .gt;
            }
        }.less);
        self.model.feed_count = rows.items.len;
        self.feed = rows.items;
        if (self.feed_arena) |*old| old.deinit();
        self.feed_arena = arena;
    }

    /// A backup file name as Mihon makes them, from the time now (UTC).
    pub fn backupName(self: *const Session, a: std.mem.Allocator) ![]const u8 {
        const ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        const days = @divFloor(ms, std.time.ms_per_day);
        const date = tachi.views.civilFromDays(@intCast(days));
        const minutes = @divFloor(ms - days * std.time.ms_per_day, std.time.ms_per_min);
        return std.fmt.allocPrint(a, "pocketmanga_{d}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}.tachibk", .{ date.year, date.month, date.day, @divFloor(minutes, 60), @mod(minutes, 60) });
    }

    pub const CategoryEdit = union(enum) { up: u32, down: u32, delete: u32 };

    pub fn editCategory(self: *Session, change: CategoryEdit) !void {
        const engine = self.browser.engine orelse return;
        var position: usize = 0;
        const id = switch (change) {
            inline else => |v| v,
        };
        const sorted = try self.model.gpa.dupe(tachi.library.Category, self.model.library.categories);
        defer self.model.gpa.free(sorted);
        std.mem.sort(tachi.library.Category, sorted, {}, struct {
            fn less(_: void, x: tachi.library.Category, y: tachi.library.Category) bool {
                return x.order < y.order;
            }
        }.less);
        for (sorted, 0..) |c, i| if (c.id == id) {
            position = i;
        };
        switch (change) {
            .up => if (position > 0) try engine.moveCategory(id, position - 1),
            .down => try engine.moveCategory(id, position + 1),
            .delete => try engine.deleteCategory(id),
        }
        try self.reloadLibrary();
    }

    pub fn addCategory(self: *Session, name: []const u8) !void {
        const engine = self.browser.engine orelse return;
        const trimmed = std.mem.trim(u8, name, " ");
        if (trimmed.len == 0) return;
        _ = engine.createCategory(trimmed) catch |err| switch (err) {
            error.DuplicateCategory => {
                self.status = "A category with that name exists";
                return;
            },
            else => return err,
        };
        try self.reloadLibrary();
    }

    /// Queues the current title's unread chapters that aren't downloaded.
    pub fn queueUnread(self: *Session) !void {
        const engine = self.browser.engine orelse return;
        const model = self.model;
        if (model.manga >= model.library.manga.len) return;
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(model.gpa);
        for (model.library.manga[model.manga].chapters) |ch| if (!model.readState(ch).read and ch.pages.len == 0) try ids.append(model.gpa, ch.id);
        const added = try engine.queue.enqueue(engine, ids.items, true);
        self.status = try std.fmt.allocPrint(model.gpa, "{d} chapters queued", .{added});
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
        self.category_id = if (groups.len > 0) groups[model.category].category.id else 0;
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
        if (self.online_arena) |*arena| arena.deinit();
        if (self.pending_arena) |*arena| arena.deinit();
        if (self.feed_arena) |*arena| arena.deinit();
        if (self.settings_arena) |*arena| arena.deinit();
    }

    pub fn loadSettings(self: *Session) !void {
        const engine = self.browser.engine orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
        errdefer arena.deinit();
        self.settings = try engine.loadSettings(arena.allocator());
        if (self.settings_arena) |*old| old.deinit();
        self.settings_arena = arena;
    }

    /// Flips a setting, or moves it to its next value, through libtachi.
    pub fn changeSetting(self: *Session, which: lib.Setting) !void {
        const engine = self.browser.engine orelse return;
        try self.loadSettings();
        var s = self.settings;
        switch (which) {
            .skip_completed => s.update.skip_completed = !s.update.skip_completed,
            .skip_unread => s.update.skip_unread = !s.update.skip_unread,
            .skip_not_started => s.update.skip_not_started = !s.update.skip_not_started,
            .skip_not_due => s.update.skip_outside_release_period = !s.update.skip_outside_release_period,
            .update_details => s.update.metadata = !s.update.metadata,
            .download_new => s.downloads.new_chapters = !s.downloads.new_chapters,
            .delete_marked_read => s.downloads.remove_after_marked_read = !s.downloads.remove_after_marked_read,
            .delete_bookmarked => s.downloads.remove_bookmarked = !s.downloads.remove_bookmarked,
            .delete_after_reading => s.downloads.remove_after_read_slots = if (s.downloads.remove_after_read_slots >= 4) -1 else s.downloads.remove_after_read_slots + 1,
            .download_ahead => s.downloads.ahead = switch (s.downloads.ahead) {
                0 => 2,
                2 => 3,
                3 => 5,
                5 => 10,
                else => 0,
            },
            .skip_read => s.reader.skip_read = !s.reader.skip_read,
            .skip_filtered => s.reader.skip_filtered = !s.reader.skip_filtered,
            .skip_duplicates => s.reader.skip_duplicates = !s.reader.skip_duplicates,
            .incognito => s.reader.incognito = !s.reader.incognito,
            .downloaded_only => s.library.downloaded_only = !s.library.downloaded_only,
            .sort_mode, .sort_ascending => {
                // Sorting goes through libtachi's rules for categories.
                var sort = self.currentSort();
                if (which == .sort_ascending) sort.ascending = !sort.ascending else {
                    const modes = std.enums.values(tachi.views.SortMode);
                    const at = std.mem.indexOfScalar(tachi.views.SortMode, modes, sort.mode) orelse 0;
                    sort.mode = modes[(at + 1) % modes.len];
                }
                try engine.setLibrarySort(self.category_id, sort);
                try self.reloadLibrary();
                try self.loadSettings();
                return;
            },
        }
        try engine.saveSettings(s);
        try self.loadSettings();
        try self.refreshRows();
    }

    /// The sort of the category the library shows.
    pub fn currentSort(self: *const Session) tachi.views.LibrarySort {
        for (self.model.library.categories) |c| if (c.id == self.category_id) return .decode(c.flags);
        return .decode(self.settings.library.sort);
    }
    pub fn act(self: *Session, action: lib.Action) !void {
        const before = self.model.current();
        const old_page = self.model.page;
        const old_screen = self.model.screen;
        const old_manga = self.model.manga;
        try self.model.dispatch(action);
        const lists = self.model.screen == .library or self.model.screen == .chapters;
        if (lists and (action == .search or action == .category or old_screen != self.model.screen or old_manga != self.model.manga or self.model.title_rows == null)) try self.refreshRows();
        const feed = self.model.screen == .updates or self.model.screen == .history or self.model.screen == .queue;
        if (feed and old_screen != self.model.screen) try self.refreshFeed();
        if (self.model.screen == .engine_settings and old_screen != .engine_settings) try self.loadSettings();
        if (self.model.screen == .backup and old_screen != .backup) try self.refreshBackups();
        if (self.model.screen == .stats and old_screen != .stats) if (self.browser.engine) |engine| {
            var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
            defer arena.deinit();
            self.stats = try engine.stats(arena.allocator());
        };
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
