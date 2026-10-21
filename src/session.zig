const std = @import("std");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Browser = @import("browser.zig").Browser;
const Image = @import("reader-image");
const Covers = @import("covers.zig");
const Regions = @import("region_service.zig");
const Viewport = @import("reader_viewport.zig");
/// A row of the updates, history or download queue screens.
pub const FeedRow = struct { pick: lib.Pick, title: []const u8, detail: []const u8, blocked: bool = false };

pub const verification_explanation = "This source requires browser verification that PocketManga cannot complete.";
pub const verification_alternative = "Find another version or use a different source.";

pub fn browserVerificationRequired(failure: []const u8) bool {
    return std.mem.eql(u8, failure, "BrowserVerificationRequired") or
        std.mem.startsWith(u8, failure, "BrowserVerificationRequired:");
}

pub const Session = struct {
    model: *lib.Model,
    io: std.Io,
    root: []const u8,
    save_path: ?[]const u8 = null,
    image: ?Image = null,
    region_service: ?*Regions.Service = null,
    display_scale: f32 = 1,
    region_viewport: Viewport.Size = .{ .width = 0, .height = 0 },
    region_epoch: u64 = 0,
    region_pixels: ?[]u8 = null,
    region_drawn: ?struct { chapter: u64, page: usize, epoch: u64, position: f64, rtl: bool, viewport: Viewport.Size } = null,
    load_image: ?*const fn (*Session, []const u8) anyerror!void = null,
    /// Decodes an owned, bounded thumbnail independently of the reader page.
    load_cover: ?*const fn (*Session, []const u8, usize, usize) anyerror!Image = null,
    covers: Covers = .{},
    /// Optional artwork never owns the foreground busy/status presentation.
    cover_job: ?*tachi.Job = null,
    /// Optional platform gate for background artwork requests.
    can_fetch_cover: ?*const fn (*Session) bool = null,
    cover_attempts: [64]?u64 = @splat(null),
    cover_attempt_next: usize = 0,
    status: []const u8 = "",
    owned_status: ?[]const u8 = null,
    status_revision: u64 = 0,
    status_transient: bool = false,
    activity: ?*const fn (bool) void = null,
    download_error: bool = false,
    download_canceled: bool = false,
    download_blocked: bool = false,
    download_identity: ?struct { series: []const u8, chapter: []const u8 } = null,
    browser: Browser = .{},
    /// Owns `model.library` once loaded through the engine.
    library_arena: ?std.heap.ArenaAllocator = null,
    /// When the reader last recorded progress, for reading time.
    last_progress_ms: ?u64 = null,
    /// Owns the model's rows and category names.
    rows_arena: ?std.heap.ArenaAllocator = null,
    /// Saved pages for resumable downloads, indexed into the current title.
    chapter_downloads: []const ?tachi.downloads.ResumeProgress = &.{},
    storage_managing: bool = false,
    storage_series: bool = false,
    storage_busy: bool = false,
    /// Owns the model's online chapter and pages.
    online_arena: ?std.heap.ArenaAllocator = null,
    /// libtachi's trackers: who is logged in, and score formats.
    trackers: tachi.tracking.State = .{},
    trackers_arena: ?std.heap.ArenaAllocator = null,
    /// The tracker being logged in to or searched.
    tracker_id: i32 = 0,
    login_username: []const u8 = "",
    /// libtachi's extension stores, when shown.
    stores: []const tachi.stores.Store = &.{},
    stores_arena: ?std.heap.ArenaAllocator = null,
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
    pub fn regionCurrent(self: *const Session) bool {
        const drawn = self.region_drawn orelse return false;
        const chapter = self.model.current() orelse return false;
        return self.image != null and self.model.reader_presented and drawn.epoch == self.region_epoch and
            drawn.chapter == std.hash.Wyhash.hash(0, chapter.id) and drawn.page == self.model.page and
            drawn.position == self.model.reader_position and drawn.rtl == self.model.prefs.rtl and
            std.meta.eql(drawn.viewport, self.region_viewport);
    }
    pub fn clearRegionImage(self: *Session) void {
        if (self.region_pixels) |pixels| self.model.gpa.free(pixels);
        self.region_pixels = null;
        self.region_drawn = null;
        if (self.region_service != null) self.image = null;
    }
    pub fn acceptRegion(self: *Session, result: Regions.Result) !bool {
        const request = result.request;
        const model = self.model;
        const chapter = model.current() orelse return false;
        if (model.screen != .reader or model.page != request.page or self.region_epoch != request.epoch or
            !std.mem.eql(u8, chapter.id, request.chapter) or model.reader_position != request.position or
            model.reader_pending_end != request.backward or model.prefs.rtl != request.rtl or
            !std.meta.eql(self.region_viewport, request.viewport)) return false;
        switch (result.value) {
            .prefetched => return false,
            .failure => |failure| {
                self.clearRegionImage();
                try self.formatStatus("Cannot open page: {s}", .{failure});
                return false;
            },
            .frame => |frame| {
                const accepted_at = std.Io.Clock.boot.now(self.io);
                const pixels = blk: {
                    const owned = try model.gpa.dupe(u8, frame.pixels);
                    errdefer model.gpa.free(owned);
                    try model.configureReader(frame.source, request.viewport);
                    break :blk owned;
                };
                model.reader_geometry = frame.geometry;
                self.clearRegionImage();
                self.region_pixels = pixels;
                self.image = .{ .width = frame.rect.width, .height = frame.rect.height, .pixels = pixels, .revision = frame.revision, .native_scale = self.display_scale };
                self.region_drawn = .{ .chapter = std.hash.Wyhash.hash(0, chapter.id), .page = model.page, .epoch = self.region_epoch, .position = model.reader_position, .rtl = model.prefs.rtl, .viewport = request.viewport };
                self.setStatus("");
                self.recordProgress();
                try self.saveDisplayPreferences();
                if (result.ready_at) |ready_at| std.log.info("Reader region {s}: accepted delivery_ms={d} apply_ms={d}", .{ request.relative, ready_at.durationTo(accepted_at).toMilliseconds(), accepted_at.durationTo(std.Io.Clock.boot.now(self.io)).toMilliseconds() });
                return true;
            },
        }
    }
    fn saveDisplayPreferences(self: *Session) !void {
        if (!self.model.dirty) return;
        if (self.save_path) |path| {
            lib.writeJson(self.model.gpa, self.io, path, self.model.prefs) catch |err| {
                try self.formatStatus("Settings not saved: {s}", .{@errorName(err)});
                return;
            };
            self.model.dirty = false;
        }
    }
    pub fn beginCoverFrame(self: *Session) void {
        self.covers.beginFrame();
    }

    fn decodeCover(self: *Session, path: []const u8, width: usize, height: usize) !Image {
        return self.load_cover.?(self, path, width, height);
    }

    fn coverHash(source: i64, url: []const u8) u64 {
        return std.hash.Wyhash.hash(@bitCast(source), url);
    }

    fn requestCover(self: *Session, manga: lib.Manga) void {
        if (self.cover_job != null or self.browser.busy != null) return;
        // Artwork may start the extension worker on a cold library screen,
        // but must never compete with page decoding while reading.
        if (self.model.screen == .reader) return;
        const engine = self.browser.engine orelse return;
        if (self.can_fetch_cover) |ready| if (!ready(self)) return;
        const source = manga.source_id orelse return;
        const remote = manga.remote orelse return;
        const url = remote.thumbnailUrl orelse return;
        if (url.len == 0) return;
        const hash = coverHash(source, url);
        for (self.cover_attempts) |attempt| if (attempt == hash) return;
        self.cover_attempts[self.cover_attempt_next] = hash;
        self.cover_attempt_next = (self.cover_attempt_next + 1) % self.cover_attempts.len;
        // Job.start clones source/URL before the library snapshot can change.
        // The retained worker handles source headers and authenticated images.
        // Optional artwork never opens a Wi-Fi dialog.
        self.cover_job = tachi.Job.start(engine, .{ .cover = .{ .source = source, .url = url } }) catch |err| {
            std.log.warn("Cannot fetch cover: {s}", .{@errorName(err)});
            return;
        };
        self.updateActivity();
    }

    pub fn cancelCoverJob(self: *Session) void {
        const job = self.cover_job orelse return;
        self.cover_job = null;
        const request = job.request.cover;
        const hash = coverHash(request.source, request.url);
        for (&self.cover_attempts) |*attempt| if (attempt.* == hash) {
            attempt.* = null;
        };
        job.cancel();
        job.deinit();
        self.updateActivity();
    }

    fn pollCover(self: *Session) void {
        const job = self.cover_job orelse return;
        if (!job.done.load(.acquire)) return;
        job.join();
        self.cover_job = null;
        defer job.deinit();
        if (job.failure) |failure| std.log.warn("Cannot fetch cover: {s}", .{failure});
    }

    /// Cached artwork is independent of the reader image. Missing remote
    /// artwork loads one at a time while the library remains interactive.
    pub fn coverImage(self: *Session, manga: lib.Manga) ?*Image {
        if (self.load_cover == null) return null;
        var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
        defer arena.deinit();
        const path = if (self.browser.engine) |engine|
            engine.coverPath(arena.allocator(), manga) catch return null
        else
            manga.cover;
        const relative = path orelse {
            self.requestCover(manga);
            return null;
        };
        if (!lib.safePath(relative)) return null;
        return self.covers.get(self.model.gpa, relative, self, decodeCover) catch null;
    }

    /// Sets a static message, releasing any previously formatted status.
    pub fn setStatus(self: *Session, comptime message: []const u8) void {
        if (self.owned_status) |owned| self.model.gpa.free(owned);
        self.owned_status = null;
        self.status = message;
        self.status_revision +%= 1;
        self.status_transient = false;
    }

    pub fn notify(self: *Session, comptime message: []const u8) void {
        self.setStatus(message);
        self.status_transient = true;
    }

    fn ownStatus(self: *Session, message: []const u8) void {
        if (self.owned_status) |owned| self.model.gpa.free(owned);
        self.owned_status = message;
        self.status = message;
        self.status_revision +%= 1;
        self.status_transient = false;
    }

    /// Allocate before replacing: formatting may borrow the current status.
    pub fn formatStatus(self: *Session, comptime format: []const u8, args: anytype) !void {
        self.ownStatus(try std.fmt.allocPrint(self.model.gpa, format, args));
    }

    pub fn dismissError(self: *Session) void {
        self.download_error = false;
        self.download_canceled = false;
        self.download_blocked = false;
        self.clearDownloadIdentity();
        self.setStatus("");
    }

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
        if (std.mem.eql(u8, failure, "StorageUnavailable")) return self.model.gpa.dupe(u8, "The SD card is unavailable. Insert the original card to resume, or select internal storage for new downloads in More > Manage storage.");
        if (self.download_canceled) return if (total > 0) std.fmt.allocPrint(self.model.gpa, "Download paused {d}/{d} · Tap to resume", .{ done, total }) else self.model.gpa.dupe(u8, "No pages were saved.");
        if (total == 0) return if (self.download_blocked) std.fmt.allocPrint(self.model.gpa, "{s} {s}", .{ verification_explanation, verification_alternative }) else self.model.gpa.dupe(u8, failure);
        if (self.download_blocked) return std.fmt.allocPrint(self.model.gpa, "{d}/{d} pages saved. {s} {s}", .{ done, total, verification_explanation, verification_alternative });
        return std.fmt.allocPrint(self.model.gpa, "{d}/{d} pages saved. {s}", .{ done, total, failure });
    }
    pub fn updateActivity(self: *Session) void {
        const queue_running = if (self.browser.engine) |engine| engine.queue.running() else false;
        if (self.activity) |activity| activity(queue_running or self.browser.loading_sources != null or (if (self.browser.busy) |job| !job.done.load(.acquire) else if (self.cover_job) |job| !job.done.load(.acquire) else false));
    }
    pub fn start(self: *Session, request: tachi.engine.Request) void {
        self.cancelCoverJob();
        // A new foreground operation can restore connectivity or source
        // credentials. Retry failed artwork after that explicit user action.
        self.cover_attempts = @splat(null);
        defer self.updateActivity();
        if (request == .download) self.download_blocked = false;
        if ((request == .download or request == .read) and self.browser.busy == null) self.rememberDownload(if (request == .download) request.download else request.read.chapter) catch {
            self.setStatus("Cannot start download: out of memory");
            self.download_error = true;
            self.download_canceled = false;
            return;
        };
        self.browser.start(request) catch |err| {
            self.download_error = request == .download;
            self.download_canceled = false;
            self.formatStatus("{s}", .{@errorName(err)}) catch self.setStatus("Operation failed");
        };
    }
    pub fn detachBrowseStartup(self: *Session) bool {
        const job = self.browser.busy orelse return true;
        if (job.request != .sources) return false;
        self.browser.loading_sources = job;
        self.browser.busy = null;
        return true;
    }

    pub fn poll(self: *Session) !void {
        defer self.updateActivity();
        self.pollCover();
        if (self.browser.busy == null) if (self.browser.loading_sources) |job| {
            if (job.done.load(.acquire)) {
                self.browser.busy = job;
                self.browser.loading_sources = null;
            }
        };
        // Background downloads may have kept the worker alive when reading began.
        if (self.model.screen == .reader and self.browser.busy == null and self.browser.loading_sources == null) if (self.browser.engine) |engine| {
            if (!engine.queue.running() and engine.backend.warm()) engine.backend.release();
        };
        if (self.model.screen == .queue and self.browser.busy == null) try self.refreshFeed();
        const job = self.browser.busy orelse return;
        if (!job.done.load(.acquire)) return;
        job.join();
        self.browser.busy = null;
        var owned_job: ?*tachi.Job = job;
        defer if (owned_job) |owned| owned.deinit();
        if (job.result.library_changed) try self.reloadLibrary() else if (job.request == .download) {
            // Partial files change without a library write, including cancellation.
            // Refresh before returning on failure so the chapter can resume immediately.
            try self.refreshRows();
        }
        if (job.request == .add_store or job.request == .refresh_stores) try self.loadStores();
        if (job.request == .tracker and job.failure == null and job.request.tracker.operation == .login) {
            try self.loadTrackers();
            self.model.screen = .trackers;
        }
        if (self.model.screen == .backup) try self.refreshBackups();
        self.download_error = job.failure != null and job.request == .download;
        self.download_canceled = self.download_error and std.mem.eql(u8, job.failure.?, "Canceled");
        self.download_blocked = self.download_error and browserVerificationRequired(job.failure.?);
        if (self.download_error) try self.rememberDownload(job.request.download);
        self.ownStatus(if (job.failure) |failure|
            if (job.request == .download) try self.downloadDetail(job, failure) else try self.model.gpa.dupe(u8, failure)
        else
            try self.model.gpa.dupe(u8, job.result.message));
        self.status_transient = job.failure == null;
        if (job.failure != null) {
            if (self.browser.pending_chapter) |id| self.model.gpa.free(id);
            self.browser.pending_chapter = null;
            if (job.request == .browse and self.browser.titles != null) self.browser.page = self.browser.titles.?.request.browse.page;
            return;
        }
        if (job.request == .read) {
            try self.openOnline(job.request.read.chapter, job.result.pages);
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
            .tracker => &self.browser.tracking,
            else => null,
        };
        if (slot) |target| {
            const old = target.*;
            target.* = job;
            errdefer target.* = old;
            if (target == &self.browser.sources) try self.browser.refreshSourceRows(self.model.gpa);
            if (old) |previous| previous.deinit();
            owned_job = null;
        }
    }
    pub fn reloadLibrary(self: *Session) !void {
        self.cancelCoverJob();
        const engine = self.browser.engine orelse return;
        {
            var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
            errdefer arena.deinit();
            const library = try engine.loadLibrary(arena.allocator());
            // Extensions disagree about their source order. Persist number
            // sorting so the list, reader navigation and mark-previous action
            // all use the same normalized order, including after a restart.
            for (@constCast(library.manga)) |*manga| {
                var flags: tachi.views.ChapterFlags = .decode(manga.chapter_flags);
                if (flags.sort != .source) continue;
                flags.sort = .number;
                const normalized = flags.encode(manga.chapter_flags);
                try engine.setChapterFlags(manga.id, normalized);
                manga.chapter_flags = normalized;
            }
            self.covers.deinit(self.model.gpa);
            self.model.clearReading();
            if (self.library_arena) |*old| old.deinit();
            self.model.library = library;
            self.library_arena = arena;
        }
        try self.refreshRows();
    }

    pub fn loadTrackers(self: *Session) !void {
        const engine = self.browser.engine orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
        errdefer arena.deinit();
        self.trackers = (try engine.loadTrackers(arena.allocator())).*;
        if (self.trackers_arena) |*old| old.deinit();
        self.trackers_arena = arena;
    }

    pub const TrackEdit = union(enum) { status: i32, score: i32, refresh: i32, unbind: i32, search: i32, bind: usize, logout: i32, login: i32 };

    /// A tracking choice: through libtachi's tracking jobs, or its logout.
    pub fn track(self: *Session, choice: TrackEdit) !void {
        const engine = self.browser.engine orelse return;
        const model = self.model;
        const manga = if (model.manga < model.library.manga.len) model.library.manga[model.manga] else null;
        switch (choice) {
            .logout => |id| {
                try engine.trackerLogout(id);
                try self.loadTrackers();
            },
            .login => |id| {
                self.tracker_id = id;
                const t = tachi.tracking.get(id) orelse return;
                // Komga, Kavita and Suwayomi use the extension's server: no account.
                if (t.enhanced) {
                    self.start(.{ .tracker = .{ .id = id, .operation = .{ .login = .{ .username = "user", .password = "pass" } } } });
                } else model.screen = .tracker_login;
            },
            .search => |id| {
                self.tracker_id = id;
                // Server trackers find the title by its source, not its name.
                if ((tachi.tracking.get(id) orelse return).enhanced) {
                    self.start(.{ .track_match = .{ .manga_id = (manga orelse return).id } });
                    return;
                }
                model.screen = .track_search;
                self.start(.{ .tracker = .{ .id = id, .operation = .{ .search = (manga orelse return).title } } });
            },
            .bind => |row| {
                const job = self.browser.tracking orelse return;
                const matches = job.result.tracking_reply.matches;
                if (row >= matches.len) return;
                model.screen = .tracking;
                self.start(.{ .track_bind = .{ .manga_id = (manga orelse return).id, .track = matches[row].track } });
            },
            .refresh => self.start(.{ .track_refresh = .{ .manga_id = (manga orelse return).id } }),
            .unbind => |id| self.start(.{ .track_unbind = .{ .manga_id = (manga orelse return).id, .tracker_id = id } }),
            .status, .score => |id| {
                const m = manga orelse return;
                const t = tachi.tracking.get(id) orelse return;
                const bound = for (m.tracks) |tr| {
                    if (tr.tracker_id == id) break tr;
                } else return;
                const value: tachi.tracking.Setter = if (choice == .status) blk: {
                    var at: usize = 0;
                    for (t.statuses, 0..) |st, i| if (st.value == bound.status) {
                        at = i;
                    };
                    break :blk .{ .status = t.statuses[(at + 1) % t.statuses.len].value };
                } else blk: {
                    const count = t.scoreCount(self.trackers.formats);
                    if (count == 0) return;
                    var at: usize = 0;
                    for (0..count) |i| if ((t.indexToScore(self.trackers.formats, i) catch 0) <= bound.score) {
                        at = i;
                    };
                    break :blk .{ .score_index = (at + 1) % count };
                };
                self.start(.{ .track_set = .{ .manga_id = m.id, .tracker_id = id, .value = value } });
            },
        }
    }

    pub fn setLoginUsername(self: *Session, name: []const u8) !void {
        const copy = try self.model.gpa.dupe(u8, name);
        if (self.login_username.len > 0) self.model.gpa.free(self.login_username);
        self.login_username = copy;
    }

    pub fn loadStores(self: *Session) !void {
        const engine = self.browser.engine orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
        errdefer arena.deinit();
        self.stores = try engine.extensionStores(arena.allocator());
        if (self.stores_arena) |*old| old.deinit();
        self.stores_arena = arena;
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
        {
            var arena: std.heap.ArenaAllocator = .init(model.gpa);
            errdefer arena.deinit();
            const a = arena.allocator();
            const copies = try a.alloc([]const u8, pages.len);
            for (pages, copies) |page, *copy| copy.* = try a.dupe(u8, page);
            const id = try a.dupe(u8, chapter_id);
            if (self.online_arena) |*old| old.deinit();
            model.online_chapter = id;
            model.online_pages = copies;
            self.online_arena = arena;
        }
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
            .upcoming => {
                const library = if (self.browser.engine) |engine| try engine.loadLibrary(a) else model.library;
                const now = std.Io.Clock.real.now(self.io).toMilliseconds();
                for (try tachi.views.upcoming(a, library, settings.updates.upcoming_categories, settings.updates.upcoming_exclude_categories, @intCast(now), 0)) |m| {
                    const first = if (m.chapters.len > 0) m.chapters[0].id else continue;
                    const pick = picks.get(first) orelse continue;
                    const days = std.math.divCeil(i64, m.next_update - @as(i64, @intCast(now)), std.time.ms_per_day) catch 0;
                    try rows.append(a, .{ .pick = .{ .manga = pick.manga, .chapter = 0 }, .title = m.title, .detail = if (days <= 0) "Expected today" else try std.fmt.allocPrint(a, "Expected in {d} days", .{days}) });
                }
            },
            .queue => if (self.browser.engine) |engine| {
                for (try engine.queue.snapshot(engine, a)) |entry| {
                    const pick = picks.get(entry.chapter_id) orelse continue;
                    const m = model.library.manga[pick.manga];
                    const blocked = entry.status == .failed and browserVerificationRequired(entry.failure orelse "");
                    const detail = switch (entry.status) {
                        .queued => if (entry.stage == .pages_ready) "Pages ready" else "Queued",
                        .downloading => if (entry.stage == .listing_pages) switch (entry.phase) {
                            .starting => "Loading worker",
                            .extension_loading => "Loading extension",
                            .operation => "Listing pages",
                        } else if (entry.pages_total > 0) try std.fmt.allocPrint(a, "Downloading {d}/{d}", .{ entry.pages_done, entry.pages_total }) else switch (entry.phase) {
                            .starting => "Loading worker",
                            .extension_loading => "Loading extension",
                            .operation => "Listing pages",
                        },
                        .failed => if (blocked) "Cannot download: browser verification" else if (std.mem.eql(u8, entry.failure orelse "", "StorageUnavailable")) "SD card unavailable: insert the original card" else try std.fmt.allocPrint(a, "Failed: {s}", .{entry.failure orelse "error"}),
                    };
                    try rows.append(a, .{ .pick = pick, .title = m.title, .blocked = blocked, .detail = if (blocked) try std.fmt.allocPrint(a, "{s} / {s}", .{ detail, m.chapters[pick.chapter].title }) else try std.fmt.allocPrint(a, "{s}  /  {s}", .{ m.chapters[pick.chapter].title, detail }) });
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

    pub const Edit = union(enum) { mark_read, mark_unread, mark_previous, bookmark, unbookmark, download, delete_download, title_read, title_unread, remove_title, toggle_category: u32, migrate, read_online, options, chapter_sort, chapter_direction, filter_unread, filter_downloaded, filter_bookmarked, toggle_scanlator: u32, interval };

    /// A title's scanlation groups. The caller owns the slice; strings borrow
    /// from the library.
    pub fn scanlators(self: *const Session, a: std.mem.Allocator) ![]const []const u8 {
        const model = self.model;
        if (model.manga >= model.library.manga.len) return &.{};
        var groups: std.ArrayList([]const u8) = .empty;
        errdefer groups.deinit(a);
        for (model.library.manga[model.manga].chapters) |ch| if (ch.scanlator) |group| {
            const seen = for (groups.items) |g| {
                if (std.mem.eql(u8, g, group)) break true;
            } else false;
            if (!seen) try groups.append(a, group);
        };
        return groups.toOwnedSlice(a);
    }

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
            .download => {
                try self.connectForDownloads();
                _ = try engine.queue.enqueue(engine, one, true);
            },
            .delete_download => if (try engine.deleteDownloads(one) == 0) {
                self.setStatus("Kept by the download deletion settings");
            },
            .title_read, .title_unread => {
                _ = try engine.markTitleRead(manga.id, choice == .title_read);
                back = .library;
            },
            .remove_title => {
                try engine.setFavorite(manga.id, false);
                back = .library;
            },
            .options => {
                model.screen = .title_options;
                return;
            },
            .chapter_sort, .chapter_direction, .filter_unread, .filter_downloaded, .filter_bookmarked => {
                var flags: tachi.views.ChapterFlags = .decode(manga.chapter_flags);
                const next = struct {
                    fn tri(state: tachi.views.TriState) tachi.views.TriState {
                        return switch (state) {
                            .disabled => .include,
                            .include => .exclude,
                            .exclude => .disabled,
                        };
                    }
                };
                switch (choice) {
                    .chapter_sort => {
                        const sorts = [_]tachi.views.ChapterSort{ .number, .upload, .alphabetical };
                        const at = std.mem.indexOfScalar(tachi.views.ChapterSort, &sorts, flags.sort) orelse 0;
                        flags.sort = sorts[(at + 1) % sorts.len];
                    },
                    .chapter_direction => flags.ascending = !flags.ascending,
                    .filter_unread => flags.unread = next.tri(flags.unread),
                    .filter_downloaded => flags.downloaded = next.tri(flags.downloaded),
                    else => flags.bookmarked = next.tri(flags.bookmarked),
                }
                try engine.setChapterFlags(manga.id, flags.encode(manga.chapter_flags));
                back = if (model.screen == .chapters) .chapters else .title_options;
            },
            .toggle_scanlator => |index| {
                var arena: std.heap.ArenaAllocator = .init(model.gpa);
                defer arena.deinit();
                const a = arena.allocator();
                const groups = try self.scanlators(a);
                if (index >= groups.len) return;
                var excluded: std.ArrayList([]const u8) = .empty;
                var was = false;
                for (manga.excluded_scanlators) |g| {
                    if (std.mem.eql(u8, g, groups[index])) was = true else try excluded.append(a, g);
                }
                if (!was) try excluded.append(a, groups[index]);
                try engine.setExcludedScanlators(manga.id, excluded.items);
                back = .title_options;
            },
            .interval => {
                const days: u31 = switch (@abs(manga.fetch_interval)) {
                    0 => 1,
                    1 => 2,
                    2 => 3,
                    3 => 7,
                    7 => 14,
                    14 => 28,
                    else => 0,
                };
                // Positive intervals are libtachi's estimates; only custom ones cycle on.
                try engine.setFetchInterval(manga.id, if (manga.fetch_interval > 0) 1 else days);
                back = .title_options;
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
                self.setStatus("A category with that name exists");
                return;
            },
            else => return err,
        };
        try self.reloadLibrary();
    }

    /// Turns Wi-Fi on for the download queue and tells libtachi, which
    /// keeps downloads to Wi-Fi.
    pub fn connectForDownloads(self: *Session) !void {
        const engine = self.browser.engine orelse return;
        if (self.browser.ensure_network) |connect| try connect();
        engine.setNetwork(.wifi);
    }

    /// Queues the current title's unread chapters that aren't downloaded.
    pub fn queueUnread(self: *Session) !void {
        const engine = self.browser.engine orelse return;
        const model = self.model;
        if (model.manga >= model.library.manga.len) return;
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(model.gpa);
        for (model.library.manga[model.manga].chapters) |ch| if (!model.readState(ch).read and ch.pages.len == 0) try ids.append(model.gpa, ch.id);
        try self.connectForDownloads();
        const added = try engine.queue.enqueue(engine, ids.items, true);
        try self.formatStatus("{d} chapters queued", .{added});
        self.status_transient = true;
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
        var chapter_downloads: []const ?tachi.downloads.ResumeProgress = &.{};
        if (model.manga < model.library.manga.len) {
            const manga = model.library.manga[model.manga];
            const progress = try a.alloc(?tachi.downloads.ResumeProgress, manga.chapters.len);
            for (manga.chapters, progress) |ch, *saved| {
                saved.* = null;
                if (!ch.downloaded()) if (self.browser.engine) |engine| {
                    saved.* = engine.downloadProgress(a, ch.id) catch |err| blk: {
                        std.log.warn("Cannot inspect saved download {s}: {s}", .{ ch.id, @errorName(err) });
                        break :blk null;
                    };
                };
            }
            chapter_downloads = progress;
            var index: std.StringHashMapUnmanaged(usize) = .empty;
            for (manga.chapters, 0..) |ch, i| try index.put(a, ch.id, i);
            const shown = try tachi.views.chapterList(a, manga, settings.library.downloaded_only);
            const rows = try a.alloc(usize, shown.len);
            for (shown, rows) |ch, *row| row.* = index.get(ch.id).?;
            chapters = rows;
        }
        model.title_rows = titles.items;
        model.chapter_rows = chapters;
        self.chapter_downloads = chapter_downloads;
        model.categories = names;
        if (self.rows_arena) |*old| old.deinit();
        self.rows_arena = arena;
    }
    /// Live queue state, allocated in the caller's frame arena. Membership
    /// changes without replacing the library or rebuilding its chapter rows.
    pub fn queuedChapters(self: *Session, arena: std.mem.Allocator) ![]const tachi.queue.Entry {
        const engine = self.browser.engine orelse return &.{};
        return engine.queue.snapshot(engine, arena);
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
        self.clearRegionImage();
        self.cancelCoverJob();
        self.covers.deinit(self.model.gpa);
        if (self.owned_status) |owned| self.model.gpa.free(owned);
        self.clearDownloadIdentity();
        self.browser.deinit(self.model.gpa);
        if (self.activity) |activity| activity(false);
        if (self.library_arena) |*arena| arena.deinit();
        if (self.rows_arena) |*arena| arena.deinit();
        if (self.online_arena) |*arena| arena.deinit();
        if (self.pending_arena) |*arena| arena.deinit();
        if (self.stores_arena) |*arena| arena.deinit();
        if (self.trackers_arena) |*arena| arena.deinit();
        if (self.login_username.len > 0) self.model.gpa.free(self.login_username);
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
            inline .skip_completed, .skip_unread, .skip_not_started => |tag| {
                const field = &@field(s.update, @tagName(tag));
                field.* = !field.*;
            },
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
            inline .skip_read, .skip_filtered, .skip_duplicates, .incognito => |tag| {
                const field = &@field(s.reader, @tagName(tag));
                field.* = !field.*;
            },
            .downloaded_only => s.library.downloaded_only = !s.library.downloaded_only,
            .sort_mode, .sort_ascending => {
                // Sorting goes through libtachi's rules for categories.
                var sort = self.currentSort();
                if (which == .sort_ascending) sort.ascending = !sort.ascending else {
                    const modes: []const tachi.views.SortMode = &.{ .alphabetical, .last_read, .date_added, .unread_count, .total_chapters, .latest_chapter };
                    const at = std.mem.indexOfScalar(tachi.views.SortMode, modes, sort.mode) orelse 0;
                    sort.mode = modes[(at + 1) % modes.len];
                }
                try engine.setLibrarySort(self.category_id, sort);
                self.model.offset = 0;
                try self.reloadLibrary();
                try self.loadSettings();
                return;
            },
        }
        try engine.saveSettings(s);
        try self.loadSettings();
        try self.refreshRows();
    }

    pub fn setDownloadStorage(self: *Session, sd_card: bool) !void {
        const engine = self.browser.engine orelse return error.RuntimeNotConfigured;
        if (sd_card and !engine.sdAvailable()) return error.StorageUnavailable;
        try self.loadSettings();
        var settings = self.settings;
        settings.downloads.storage = if (sd_card) .sd_card else .internal;
        try engine.saveSettings(settings);
        try self.loadSettings();
        self.notify("Download destination updated");
    }

    pub fn setLibrarySort(self: *Session, mode: tachi.views.SortMode) !void {
        const engine = self.browser.engine orelse return error.RuntimeNotConfigured;
        var sort = self.currentSort();
        sort.mode = mode;
        try engine.setLibrarySort(self.category_id, sort);
        self.model.offset = 0;
        try self.reloadLibrary();
        try self.loadSettings();
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
        if (self.region_service != null and old_screen != .reader and (action == .read or action == .open_chapter)) {
            // Private viewport anchors must follow the engine's incognito policy.
            if (self.browser.engine) |engine| {
                var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
                defer arena.deinit();
                const settings = try engine.loadSettings(arena.allocator());
                self.model.reader_record_positions = !settings.reader.incognito;
                const index = if (action == .open_chapter) action.open_chapter.manga else self.model.manga;
                if (index < self.model.library.manga.len) if (self.model.library.manga[index].source_id) |id| {
                    for (self.model.library.sources) |source| if (source.id == id) {
                        for (settings.reader.incognito_extensions) |pkg| if (std.mem.eql(u8, pkg, source.pkg)) {
                            self.model.reader_record_positions = false;
                        };
                    };
                };
            }
        }
        try self.model.dispatch(action);
        if (self.model.screen == .reader) self.cancelCoverJob();
        const lists = self.model.screen == .library or self.model.screen == .chapters;
        if (lists and (action == .search or action == .category or old_screen != self.model.screen or old_manga != self.model.manga or self.model.title_rows == null)) try self.refreshRows();
        const feed = self.model.screen == .updates or self.model.screen == .history or self.model.screen == .queue or self.model.screen == .upcoming;
        if (feed and old_screen != self.model.screen) try self.refreshFeed();
        if ((self.model.screen == .engine_settings or self.model.screen == .storage) and old_screen != self.model.screen) try self.loadSettings();
        if ((self.model.screen == .trackers or self.model.screen == .tracking) and old_screen != self.model.screen) try self.loadTrackers();
        if (self.model.screen == .backup and old_screen != .backup) try self.refreshBackups();
        if (self.model.screen == .stats and old_screen != .stats) if (self.browser.engine) |engine| {
            var arena: std.heap.ArenaAllocator = .init(self.model.gpa);
            defer arena.deinit();
            self.stats = try engine.stats(arena.allocator());
        };
        if (self.model.screen == .reader and (old_screen != .reader or old_page != self.model.page or before == null or !std.mem.eql(u8, before.?.id, self.model.current().?.id))) {
            self.setStatus("");
            self.download_error = false;
            self.clearDownloadIdentity();
            // Reading needs no extensions: let a worker give its memory back.
            if (self.browser.busy == null and self.browser.loading_sources == null) if (self.browser.engine) |engine| {
                if (!engine.queue.running()) engine.backend.release();
            };
            if (self.load_image) |load| {
                const path = self.model.current().?.pages[self.model.page];
                load(self, path) catch |err| {
                    self.image = null;
                    try self.formatStatus("Cannot open page: {s}", .{@errorName(err)});
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
            try self.formatStatus("Downloads not deleted: {s}", .{@errorName(err)});
        };
        try self.saveDisplayPreferences();
    }
    /// Tells libtachi which page is shown, with the time spent since the
    /// last page (at most five minutes, so an idle reader does not count).
    /// libtachi marks the chapter read on its last page and does the rest.
    fn recordProgress(self: *Session) void {
        if (self.region_service != null and !self.regionCurrent()) return;
        self.model.progress_changed = false;
        const engine = self.browser.engine orelse return;
        const ch = self.model.current() orelse return;
        const state = self.model.readState(ch);
        const now: u64 = @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds());
        const read_ms: i64 = if (self.last_progress_ms) |last| @intCast(@min(now - last, 5 * 60 * 1000)) else 0;
        self.last_progress_ms = now;
        engine.pageShown(.{ .chapter_id = ch.id, .page = state.page, .pages = @intCast(ch.pages.len), .read_ms = read_ms, .completed = if (self.model.region_reader) self.model.page + 1 == ch.pages.len and self.model.readerAtEnd() else null }) catch |err| {
            self.formatStatus("Progress not saved: {s}", .{@errorName(err)}) catch self.setStatus("Progress not saved");
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
