const std = @import("std");
const tachi = @import("tachi");
const lib = @import("library.zig");
pub const Language = struct { code: []const u8, enabled: bool };
pub const Browser = struct {
    engine: ?*tachi.Engine = null,
    busy: ?*tachi.Job = null,
    sources: ?*tachi.Job = null,
    extensions: ?*tachi.Job = null,
    titles: ?*tachi.Job = null,
    preferences: ?*tachi.Job = null,
    /// The last global search, and the title it is finding a migration
    /// target for, if any.
    global: ?*tachi.Job = null,
    migrate_from: ?[]const u8 = null,
    /// The sources screen's rows in libtachi's order (last used, pinned,
    /// then by language), or every source with `show_hidden`.
    source_rows: []const tachi.models.SourceInfo = &.{},
    source_rows_arena: ?std.heap.ArenaAllocator = null,
    show_hidden: bool = false,
    /// The open source's place in libtachi's settings.
    source_pinned: bool = false,
    source_hidden: bool = false,
    /// Languages of the installed sources, and whether each is enabled.
    languages: []const Language = &.{},
    offset: usize = 0,
    source_id: i64 = 0,
    source_name: []const u8 = "",
    extension_pkg: []const u8 = "",
    source_configurable: bool = false,
    supports_latest: bool = false,
    latest: bool = false,
    page: i32 = 1,
    query: []const u8 = "",
    pending_chapter: ?[]const u8 = null,
    edited_preference: ?usize = null,
    ensure_network: ?*const fn () anyerror!void = null,
    pub fn start(self: *Browser, request: tachi.engine.Request) !void {
        if (self.busy != null) return error.Busy;
        const engine = self.engine orelse return error.RuntimeNotConfigured;
        switch (request) {
            .sources, .install_file, .scan_local, .preferences, .set_preference, .uninstall, .delete_download, .remove, .import_backup, .export_backup, .import_downloads, .export_downloads => {},
            else => if (self.ensure_network) |connect| try connect(),
        }
        self.busy = try tachi.Job.start(engine, request);
    }
    pub fn setSource(self: *Browser, gpa: std.mem.Allocator, source: tachi.models.SourceInfo) !void {
        const id = try source.idInt();
        const name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(name);
        const pkg = try gpa.dupe(u8, source.extensionPkg);
        if (self.source_name.len > 0) gpa.free(self.source_name);
        if (self.extension_pkg.len > 0) gpa.free(self.extension_pkg);
        self.source_id = id;
        self.source_name = name;
        self.extension_pkg = pkg;
        self.source_configurable = source.isConfigurable;
        self.supports_latest = source.supportsLatest;
    }
    pub fn setPendingChapter(self: *Browser, gpa: std.mem.Allocator, id: []const u8) !void {
        const copy = try gpa.dupe(u8, id);
        if (self.pending_chapter) |old| gpa.free(old);
        self.pending_chapter = copy;
    }
    /// A global search's results, one row per title: its source and title.
    pub const Hit = struct { source: i64, source_name: []const u8, manga: tachi.models.Manga };

    pub fn globalHit(self: *const Browser, row: usize) ?Hit {
        const job = self.global orelse return null;
        var at: usize = 0;
        for (job.result.search) |result| for (result.mangas) |manga| {
            if (at == row) return .{ .source = result.source.idInt() catch return null, .source_name = result.source.name, .manga = manga };
            at += 1;
        };
        return null;
    }

    /// Lays out the installed sources as libtachi's source list does. The
    /// local source isn't browsed here: local series come in by scanning.
    pub fn refreshSourceRows(self: *Browser, gpa: std.mem.Allocator) !void {
        const engine = self.engine orelse return;
        const job = self.sources orelse return;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var rows: std.ArrayList(tachi.models.SourceInfo) = .empty;
        if (self.show_hidden) {
            try rows.appendSlice(a, job.result.sources);
            std.mem.sort(tachi.models.SourceInfo, rows.items, {}, struct {
                fn less(_: void, x: tachi.models.SourceInfo, y: tachi.models.SourceInfo) bool {
                    return std.ascii.lessThanIgnoreCase(x.name, y.name);
                }
            }.less);
        } else {
            const list = try engine.sourceList(a, job.result.sources);
            if (list.last_used) |source| try rows.append(a, source);
            try rows.appendSlice(a, list.pinned);
            for (list.languages) |group| try rows.appendSlice(a, group.sources);
        }
        // The last used source also stays in its group, as in Mihon.
        var shown: std.ArrayList(tachi.models.SourceInfo) = .empty;
        for (rows.items) |source| if (!std.mem.eql(u8, source.id, "0")) try shown.append(a, source);
        self.source_rows = shown.items;
        const browse = (try engine.loadSettings(a)).browse;
        var languages: std.ArrayList(Language) = .empty;
        for (job.result.sources) |source| {
            const known = for (languages.items) |l| {
                if (std.mem.eql(u8, l.code, source.lang)) break true;
            } else false;
            if (known) continue;
            const enabled = for (browse.languages) |l| {
                if (std.mem.eql(u8, l, source.lang)) break true;
            } else false;
            try languages.append(a, .{ .code = source.lang, .enabled = enabled });
        }
        std.mem.sort(Language, languages.items, {}, struct {
            fn less(_: void, x: Language, y: Language) bool {
                return std.mem.lessThan(u8, x.code, y.code);
            }
        }.less);
        self.languages = languages.items;
        if (self.source_rows_arena) |*old| old.deinit();
        self.source_rows_arena = arena;
    }

    pub fn setQuery(self: *Browser, gpa: std.mem.Allocator, query: []const u8) !void {
        const copy = try gpa.dupe(u8, query);
        if (self.query.len > 0) gpa.free(self.query);
        self.query = copy;
        self.offset = 0;
    }
    pub fn count(self: *const Browser, screen: lib.Screen) usize {
        return switch (screen) {
            .sources => self.source_rows.len,
            .catalog => if (self.titles) |j| if (j.result.page) |page| page.mangas.len else 0 else 0,
            .source_settings => if (self.preferences) |j| j.result.preferences.len else 0,
            .languages => self.languages.len,
            .global_search => blk: {
                const job = self.global orelse break :blk 0;
                var hits: usize = 0;
                for (job.result.search) |result| hits += result.mangas.len;
                break :blk hits;
            },
            .extensions => blk: {
                const job = self.extensions orelse break :blk 0;
                var count_: usize = 0;
                for (job.result.extensions) |e| if (self.matches(e.name, e.lang)) {
                    count_ += 1;
                };
                break :blk count_;
            },
            else => 0,
        };
    }
    fn matches(self: *const Browser, name: []const u8, lang: []const u8) bool {
        return self.query.len == 0 or std.ascii.findIgnoreCase(name, self.query) != null or std.ascii.findIgnoreCase(lang, self.query) != null;
    }
    pub fn extensionIndex(self: *const Browser, row: usize) usize {
        var at: usize = 0;
        for (self.extensions.?.result.extensions, 0..) |e, i| if (self.matches(e.name, e.lang)) {
            if (at == row) return i;
            at += 1;
        };
        unreachable;
    }
    pub fn deinit(self: *Browser, gpa: std.mem.Allocator) void {
        if (self.engine) |engine| engine.pause();
        if (self.busy) |job| {
            job.cancel();
            job.deinit();
        }
        if (self.query.len > 0) gpa.free(self.query);
        if (self.source_name.len > 0) gpa.free(self.source_name);
        if (self.extension_pkg.len > 0) gpa.free(self.extension_pkg);
        if (self.pending_chapter) |id| gpa.free(id);
        if (self.migrate_from) |id| gpa.free(id);
        for ([_]?*tachi.Job{ self.sources, self.extensions, self.titles, self.preferences, self.global }) |snapshot| if (snapshot) |job| job.deinit();
        if (self.source_rows_arena) |*arena| arena.deinit();
    }
};
