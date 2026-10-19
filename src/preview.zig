const std = @import("std");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const smoke = @import("smoke.zig");
pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var model: lib.Model = .{ .gpa = arena.allocator(), .library = smoke.fixture };
    var session: Session = .{ .model = &model, .root = ".", .io = init.io, .load_image = smoke.sampleImage };
    try std.Io.Dir.cwd().createDirPath(init.io, "preview");
    try smoke.start(init.gpa, init.io, &session);
    defer smoke.stop();
    try smoke.writeScreen(init.gpa, init.io, "preview/library.pgm");
    try smoke.tapText("The Copper Lantern");
    try smoke.writeScreen(init.gpa, init.io, "preview/chapters.pgm");
    try smoke.tapText("Chapter 1 - A new beginning");
    try smoke.writeScreen(init.gpa, init.io, "preview/reader.pgm");
    try smoke.tapText("Aa");
    try smoke.writeScreen(init.gpa, init.io, "preview/settings.pgm");
    std.debug.print("Rendered 758x1024 application screens into preview/*.pgm\n", .{});
}
