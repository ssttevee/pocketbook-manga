const std = @import("std");
const ink = @import("fabrum-platform-inkview");
const tachi = @import("tachi");
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

/// Width and height from a PNG's IHDR chunk.
fn pngSize(io: std.Io, path: []const u8) ![2]u32 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var header: [24]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len) return error.InvalidPng;
    if (!std.mem.eql(u8, header[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, header[12..16], "IHDR")) return error.InvalidPng;
    const width = std.mem.readInt(u32, header[16..20], .big);
    const height = std.mem.readInt(u32, header[20..24], .big);
    if (width == 0 or height == 0) return error.InvalidPng;
    return .{ width, height };
}

fn loadPage(session: *Session, relative: []const u8) !void {
    const gpa = session.model.gpa;
    if (!lib.safePath(relative)) return error.UnsafePagePath;
    const path = try session.browser.engine.?.pagePath(gpa, relative);
    defer gpa.free(path);
    // Fit decode to the physical panel to bound memory on the 512MB Verse.
    const host = &ink.App(Root).instance;
    const w = host.api.ScreenWidth();
    const h = host.api.ScreenHeight();
    const ext = std.fs.path.extension(relative);
    const bitmap = if (std.ascii.eqlIgnoreCase(ext, ".png")) bitmap: {
        // LoadPNGStretch crashes fitting landscape pages itself, so fit them here.
        const size = try pngSize(session.io, path);
        const fit = @min(@as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(size[0])), @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(size[1])));
        const fw: c_int = @max(1, @as(c_int, @intFromFloat(@round(@as(f32, @floatFromInt(size[0])) * fit))));
        const fh: c_int = @max(1, @as(c_int, @intFromFloat(@round(@as(f32, @floatFromInt(size[1])) * fit))));
        break :bitmap png(path, fw, fh, 0, 1);
    } else jpeg(path, w, h, 64, 128, 1);
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
    // progress.json now only holds display preferences; libtachi keeps the
    // library and reading state.
    const prefs_path = try std.fs.path.join(gpa, &.{ root, "progress.json" });
    var model: lib.Model = .{ .gpa = gpa };
    const prefs = lib.readJson(lib.Preferences, gpa, io, prefs_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (prefs) |p| model.prefs = p.value;
    var session: Session = .{ .model = &model, .root = root, .io = io, .save_path = prefs_path, .load_image = loadPage };
    // Extensions run in the worker process; the library, downloads and the
    // local source stay here. Test emulators wrap the worker.
    const worker_exe = try std.fs.path.join(gpa, &.{ root, "bin/pocketmanga-worker" });
    var worker: tachi.worker.Client = undefined;
    try worker.init(gpa, io, .{ .exe = worker_exe, .args = &.{ "--serve", root }, .wrapper = init.minimal.environ.getPosix("POCKETMANGA_WORKER_EMULATOR") });
    defer worker.deinit();
    const ca_file = try std.fs.path.join(gpa, &.{ root, "runtime/ca.pem" });
    var engine: tachi.Engine = .init(gpa, io, worker.backend(), .{ .dir = root, .ca_file = ca_file });
    defer engine.deinit();
    // Stops tracking updates and the download queue before the worker goes.
    defer engine.queue.deinit(&engine);
    defer engine.finishTracking();
    session.browser.engine = &engine;
    engine.launched() catch |err| std.log.warn("launch upkeep: {s}", .{@errorName(err)});
    try session.reloadLibrary();
    try session.migrateProgress();
    session.browser.ensure_network = connectNetwork;
    const library_name = std.c.getenv("INKVIEW_LIBRARY") orelse "libinkview.so";
    var image_library = try std.DynLib.open(std.mem.span(library_name));
    network_connect = image_library.lookup(@TypeOf(network_connect), "NetConnect") orelse return error.MissingNetworkApi;
    jpeg = image_library.lookup(Jpeg, "LoadJPEG") orelse return error.MissingJpegDecoder;
    png = image_library.lookup(Png, "LoadPNGStretch") orelse return error.MissingPngDecoder;
    power_guard = @import("power.zig").Guard.load(&image_library);
    session.activity = updatePower;
    defer power_guard.update(false, 0);
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
    lifecycle_worker = &worker;
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
        // Press feedback must never trigger a periodic full-screen clean.
        // Reader page turns request their own full refreshes in ui.zig.
        .refresh = .{ .full_every = 0, .interactive = .dynamic },
        .context = .{ .units = 512, .breadth = 64 },
    });
}

var power_guard: @import("power.zig").Guard = .{};
fn updatePower(active: bool) void {
    power_guard.update(active, tachi.worker.tachi_now_ms());
}
var lifecycle_engine: ?*tachi.Engine = null;
var lifecycle_worker: ?*tachi.worker.Client = null;
var lifecycle_session: ?*Session = null;
var actual_main: *const fn (ink.inkview.Handler) callconv(.c) void = undefined;
var actual_close: *const fn () callconv(.c) void = undefined;
var app_handler: ink.inkview.Handler = undefined;
fn stopWorker() void {
    defer updatePower(false);
    if (lifecycle_engine) |engine| {
        engine.pause();
        if (lifecycle_session) |session| if (session.browser.busy) |job| job.cancel();
        if (lifecycle_worker) |worker| worker.close();
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
        engine.@"resume"();
    };
    if (kind == @backingInt(ink.inkview.Event.exit) or kind == @backingInt(ink.inkview.Event.background)) stopWorker();
    return app_handler(kind, p1, p2);
}
