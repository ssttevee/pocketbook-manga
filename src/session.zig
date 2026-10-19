const std = @import("std");
const lib = @import("library.zig");
const online = @import("online.zig");
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
    browser: Browser = .{},
    library_snapshot: ?std.json.Parsed(lib.Library) = null,
    pub fn start(self: *Session, request: online.Request) void {
        self.browser.start(request) catch |err| {
            self.status = std.fmt.allocPrint(self.model.gpa, "{s}", .{@errorName(err)}) catch "Operation failed";
        };
    }
    pub fn poll(self: *Session) !void {
        const job = self.browser.busy orelse return;
        if (!job.done.load(.acquire)) return;
        job.join();
        self.browser.busy = null;
        if (job.result.library_changed) try self.reloadLibrary();
        self.status = try self.model.gpa.dupe(u8, job.failure orelse job.result.message);
        if (job.failure != null) {
            if (self.browser.pending_chapter) |id| self.model.gpa.free(id);
            self.browser.pending_chapter = null;
            if (job.request == .titles and self.browser.titles != null) self.browser.page = self.browser.titles.?.request.titles.page;
            job.deinit();
            return;
        }
        if (job.result.open_id) |id| for (self.model.library.manga, 0..) |m, i| {
            if (std.mem.eql(u8, m.id, id)) {
                try self.act(.{ .open = i });
                break;
            }
        };
        if (job.request == .download) if (self.browser.pending_chapter) |id| {
            for (self.model.library.manga[self.model.manga].chapters, 0..) |ch, i| {
                if (std.mem.eql(u8, ch.id, id)) {
                    try self.act(.{ .read = i });
                    break;
                }
            }
            self.model.gpa.free(id);
            self.browser.pending_chapter = null;
        };
        const slot: ?*?*online.Job = switch (job.request) {
            .sources, .install, .install_file, .uninstall => &self.browser.sources,
            .extensions => &self.browser.extensions,
            .titles => &self.browser.titles,
            .preferences, .set_preference => &self.browser.preferences,
            else => null,
        };
        if (slot) |target| {
            if (target.*) |old| old.deinit();
            target.* = job;
        } else job.deinit();
    }
    pub fn reloadLibrary(self: *Session) !void {
        const path = try std.fs.path.join(self.model.gpa, &.{ self.root, "library.json" });
        defer self.model.gpa.free(path);
        const parsed = try lib.readJson(lib.Library, self.model.gpa, self.io, path);
        errdefer parsed.deinit();
        try lib.validate(parsed.value);
        self.model.library = parsed.value;
        if (self.library_snapshot) |old| old.deinit();
        self.library_snapshot = parsed;
    }
    pub fn deinit(self: *Session) void {
        self.browser.deinit(self.model.gpa);
        if (self.library_snapshot) |parsed| parsed.deinit();
    }
    pub fn act(self: *Session, action: lib.Action) !void {
        const before = self.model.current();
        const old_page = self.model.page;
        const old_screen = self.model.screen;
        try self.model.dispatch(action);
        if (self.model.screen == .reader and (old_screen != .reader or old_page != self.model.page or before == null or !std.mem.eql(u8, before.?.id, self.model.current().?.id))) {
            self.status = "";
            if (self.browser.busy == null) if (self.browser.engine) |engine| engine.client.shutdown(engine.gpa);
            if (self.load_image) |load| {
                const path = self.model.current().?.pages[self.model.page];
                load(self, path) catch |err| {
                    self.image = null;
                    self.status = try std.fmt.allocPrint(self.model.gpa, "Cannot open page: {s}", .{@errorName(err)});
                };
            }
        }
        if (self.model.dirty) if (self.save_path) |path| {
            lib.writeJson(self.model.gpa, self.io, path, self.model.prefs) catch |err| {
                self.status = try std.fmt.allocPrint(self.model.gpa, "Progress not saved: {s}", .{@errorName(err)});
                return;
            };
            self.model.dirty = false;
        };
    }
};
