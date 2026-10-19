const std = @import("std");
const ink = @import("fabrum-platform-inkview");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;
const f = @import("fabrum");

// The bitmap ABI is documented by libinkview's SDK. The platform loads its
// core API; the application resolves the optional image decoders here.
const Bitmap = extern struct { width: u16, height: u16, depth: u16, scanline: u16 };
const Jpeg = *const fn ([*:0]const u8, c_int, c_int, c_int, c_int, c_int) callconv(.c) ?*Bitmap;
const Png = *const fn ([*:0]const u8, c_int, c_int, c_int, c_int) callconv(.c) ?*Bitmap;
var jpeg: Jpeg = undefined;
var png: Png = undefined;
var network_connect: *const fn (?[*:0]const u8) callconv(.c) c_int = undefined;
fn connectNetwork() !void {
    if (network_connect(null) != 0) return error.WifiConnectionFailed;
}
var page_pixels: []u8 = &.{};

fn loadPage(session: *Session, relative: []const u8) !void {
    const gpa = session.model.gpa;
    if (!lib.safePath(relative)) return error.UnsafePagePath;
    const path = try @import("downloads.zig").pagePath(gpa, session.root, relative);
    defer gpa.free(path);
    // Fit decode to the physical panel to bound memory on the 512MB Verse.
    const host = &ink.App(Root).instance;
    const w = host.api.ScreenWidth();
    const h = host.api.ScreenHeight();
    const ext = std.fs.path.extension(relative);
    const bitmap = if (std.ascii.eqlIgnoreCase(ext, ".png")) png(path, w, h, 1, 1) else jpeg(path, w, h, 64, 128, 1);
    const bm = bitmap orelse return error.ImageDecodeFailed;
    defer std.c.free(bm);
    const depth = bm.depth & 0xff;
    if (bm.width == 0 or bm.height == 0 or bm.width > 4096 or bm.height > 4096) return error.InvalidBitmap;
    if (depth != 8 and depth != 4 and depth != 1 and depth != 24) return error.UnsupportedBitmapDepth;
    if (@as(usize, bm.scanline) < (@as(usize, bm.width) * depth + 7) / 8) return error.InvalidBitmap;
    const bytes: [*]const u8 = @as([*]const u8, @ptrCast(bm)) + @sizeOf(Bitmap);
    const pixels = try gpa.alloc(u8, @as(usize, bm.width) * bm.height);
    errdefer gpa.free(pixels);
    for (0..bm.height) |y| for (0..bm.width) |x| {
        const row = bytes + y * bm.scanline;
        pixels[y * bm.width + x] = switch (depth) {
            8 => row[x],
            4 => @as(u8, if (x % 2 == 0) row[x / 2] >> 4 else row[x / 2] & 15) * 17,
            1 => if ((row[x / 8] >> @as(u3, @intCast(7 - x % 8))) & 1 == 1) 255 else 0,
            24 => @intCast((@as(u32, row[x * 3]) * 299 + @as(u32, row[x * 3 + 1]) * 587 + @as(u32, row[x * 3 + 2]) * 114) / 1000),
            else => unreachable,
        };
    };
    gpa.free(page_pixels);
    page_pixels = pixels;
    session.image = .{ .width = bm.width, .height = bm.height, .pixels = pixels, .revision = std.hash.Wyhash.hash(0, relative) };
}
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var device_io = @import("device_io.zig").DeviceIo.init(init.io);
    const io = device_io.io();
    var args = init.minimal.args.iterate();
    _ = args.next();
    const root = args.next() orelse "/mnt/ext1/applications/pocketmanga";
    try std.Io.Dir.cwd().createDirPath(io, root);
    const library_path = try std.fs.path.join(gpa, &.{ root, "library.json" });
    const prefs_path = try std.fs.path.join(gpa, &.{ root, "progress.json" });
    const library = lib.readJson(lib.Library, gpa, io, library_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var model: lib.Model = .{ .gpa = gpa, .library = if (library) |p| p.value else .{} };
    try lib.validate(model.library);
    const prefs = lib.readJson(lib.Preferences, gpa, io, prefs_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (prefs) |p| model.prefs = p.value;
    var session: Session = .{ .model = &model, .root = root, .io = io, .save_path = prefs_path, .load_image = loadPage };
    var engine: @import("online.zig").Engine = .{ .gpa = gpa, .io = io, .root = root, .environ = init.minimal.environ };
    session.browser.engine = &engine;
    session.browser.ensure_network = connectNetwork;
    const library_name = std.c.getenv("INKVIEW_LIBRARY") orelse "libinkview.so";
    var image_library = try std.DynLib.open(std.mem.span(library_name));
    network_connect = image_library.lookup(@TypeOf(network_connect), "NetConnect") orelse return error.MissingNetworkApi;
    jpeg = image_library.lookup(Jpeg, "LoadJPEG") orelse return error.MissingJpegDecoder;
    png = image_library.lookup(Png, "LoadPNGStretch") orelse return error.MissingPngDecoder;
    // The packaged binary itself can verify JNI and every required InkView
    // symbol without entering the hardware event loop. Nothing enables this
    // during normal launch; the firmware integration tests set the variable.
    if (init.minimal.environ.getPosix("POCKETMANGA_RUNTIME_CHECK")) |mode| {
        const handle = std.c.dlopen(library_name, .{ .NOW = true }) orelse {
            if (std.c.dlerror()) |message| std.debug.print("{s}\n", .{message});
            return error.InkViewRelocationFailed;
        };
        defer _ = std.c.dlclose(handle);
        _ = try ink.inkview.Api.load(library_name);
        std.debug.print("InkView loaded with RTLD_NOW; required symbols resolved (stopping before InkViewMain).\n", .{});
        try @import("runtime_probe.zig").run(gpa, io, init.minimal.environ, root, mode, init.minimal.environ.getPosix("POCKETMANGA_FIXTURE"));
        return;
    }
    lifecycle_engine = &engine;
    lifecycle_session = &session;
    var api = try ink.inkview.Api.load(library_name);
    actual_main = api.InkViewMain;
    actual_close = api.CloseApp;
    api.InkViewMain = mainWithLifecycle;
    api.CloseApp = closeWithLifecycle;
    try ink.App(Root).run(gpa, io, api, .{}, .{
        .library = library_name,
        .fonts = &.{.{ .name = "Go", .data = @embedFile("fonts/Go-Regular.ttf") }},
        .provide = &.{f.app.RootValue.of(&session)},
        // Back is routed through fabrum: chapter list -> library -> exit.
        .close_key = null,
        .context = .{ .units = 512, .breadth = 64 },
    });
}

var lifecycle_engine: ?*@import("online.zig").Engine = null;
var lifecycle_session: ?*Session = null;
var actual_main: *const fn (ink.inkview.Handler) callconv(.c) void = undefined;
var actual_close: *const fn () callconv(.c) void = undefined;
var app_handler: ink.inkview.Handler = undefined;
fn stopWorker() void {
    if (lifecycle_engine) |engine| {
        engine.interrupt();
        if (lifecycle_session) |session| if (session.browser.busy) |job| job.cancel();
        engine.deinit();
    }
}
fn mainWithLifecycle(handler: ink.inkview.Handler) callconv(.c) void {
    app_handler = handler;
    actual_main(eventWithLifecycle);
}
fn closeWithLifecycle() callconv(.c) void {
    stopWorker();
    actual_close();
}
fn eventWithLifecycle(kind: c_int, p1: c_int, p2: c_int) callconv(.c) c_int {
    if (kind == @backingInt(ink.inkview.Event.foreground)) if (lifecycle_engine) |engine| {
        engine.paused.store(false, .release);
    };
    if (kind == @backingInt(ink.inkview.Event.exit) or kind == @backingInt(ink.inkview.Event.background)) stopWorker();
    return app_handler(kind, p1, p2);
}
