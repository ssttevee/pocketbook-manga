const std = @import("std");
const lib = @import("library.zig");
const Image = @import("reader-image");
pub const Session = struct {
    model: *lib.Model,
    io: std.Io,
    root: []const u8,
    save_path: ?[]const u8 = null,
    image: ?Image = null,
    load_image: ?*const fn (*Session, []const u8) anyerror!void = null,
    status: []const u8 = "",
    pub fn act(self: *Session, action: lib.Action) !void {
        const before = self.model.current();
        const old_page = self.model.page;
        const old_screen = self.model.screen;
        try self.model.dispatch(action);
        if (self.model.screen == .reader and (old_screen != .reader or old_page != self.model.page or before == null or !std.mem.eql(u8, before.?.id, self.model.current().?.id))) {
            self.status = "";
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
