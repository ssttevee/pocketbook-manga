const std = @import("std");
const online = @import("online.zig");
const lib = @import("library.zig");
pub const Browser = struct {
    engine: ?*online.Engine = null,
    busy: ?*online.Job = null,
    sources: ?*online.Job = null,
    extensions: ?*online.Job = null,
    titles: ?*online.Job = null,
    preferences: ?*online.Job = null,
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
    pub fn start(self: *Browser, request: online.Request) !void {
        if (self.busy != null) return error.Busy;
        const engine = self.engine orelse return error.RuntimeNotConfigured;
        switch (request) {
            .sources, .scan, .preferences, .set_preference, .uninstall => {},
            else => if (self.ensure_network) |connect| try connect(),
        }
        self.busy = try online.Job.start(engine, request);
    }
    pub fn setQuery(self: *Browser, gpa: std.mem.Allocator, query: []const u8) !void {
        const copy = try gpa.dupe(u8, query);
        if (self.query.len > 0) gpa.free(self.query);
        self.query = copy;
        self.offset = 0;
    }
    pub fn count(self: *const Browser, screen: lib.Screen) usize {
        return switch (screen) {
            .sources => if (self.sources) |j| j.result.sources.len else 0,
            .catalog => if (self.titles) |j| if (j.result.titles) |page| page.mangas.len else 0 else 0,
            .source_settings => if (self.preferences) |j| j.result.preferences.len else 0,
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
        if (self.busy) |job| {
            job.cancelled.store(true, .release);
            job.deinit();
        }
        if (self.query.len > 0) gpa.free(self.query);
        if (self.source_name.len > 0) gpa.free(self.source_name);
        if (self.extension_pkg.len > 0) gpa.free(self.extension_pkg);
        if (self.pending_chapter) |id| gpa.free(id);
        for ([_]?*online.Job{ self.sources, self.extensions, self.titles, self.preferences }) |snapshot| if (snapshot) |job| job.deinit();
    }
};
