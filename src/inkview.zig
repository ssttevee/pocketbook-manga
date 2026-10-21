const std = @import("std");
const ink = @import("fabrum-platform-inkview");
const tachi = @import("tachi");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;
const f = @import("fabrum");

const Vips = @import("vips.zig");
const Regions = @import("region_service.zig");
var codecs: ?*const Vips.Library = null;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
var network_connect: *const fn (?[*:0]const u8) callconv(.c) c_int = undefined;
fn connectNetwork() !void {
    if (network_connect(null) != 0) return error.WifiConnectionFailed;
}
fn decodeImage(session: *Session, relative: []const u8, width: usize, height: usize) !@import("reader-image") {
    if (!lib.safePath(relative)) return error.UnsafePagePath;
    const decoder = codecs orelse return error.ImageRuntimeUnavailable;
    const gpa = session.model.gpa;
    const path = try session.browser.engine.?.pagePath(gpa, relative);
    defer gpa.free(path);
    const terminated = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(terminated);
    const source = try decoder.probe(terminated);
    const scale = @min(@as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(source.width)), @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(source.height)));
    var image = try decoder.open(terminated, scale);
    defer image.deinit();
    const w = @min(width, image.size.width);
    const h = @min(height, image.size.height);
    const pixels = try gpa.alloc(u8, w * h);
    errdefer gpa.free(pixels);
    try image.region(0, 0, w, h, pixels, w);
    return .{ .width = w, .height = h, .pixels = pixels, .revision = std.hash.Wyhash.hash(0, pixels) };
}
fn loadPage(session: *Session, _: []const u8) !void {
    // The declarative reader task performs all source I/O and decoding. Input
    // callbacks only invalidate the previous frame and capture panel scale.
    session.clearRegionImage();
    session.region_epoch +%= 1;
    session.display_scale = ink.App(Root).instance.screen.scale;
}

fn canFetchCover(_: *Session) bool {
    const worker = lifecycle_worker orelse return false;
    // Cold library screens keep placeholders. Once browsing has warmed the
    // worker, optional artwork can load without competing with JVM startup
    // or waiting for a released worker to finish saving its startup cache.
    return worker.alive() and worker.workerReady();
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
    var model: lib.Model = .{ .gpa = gpa, .region_reader = true, .reader_requires_presentation = true };
    const prefs = lib.readJson(lib.Preferences, gpa, io, prefs_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (prefs) |p| model.prefs = p.value;
    var session: Session = .{ .model = &model, .root = root, .io = io, .save_path = prefs_path, .load_image = loadPage, .load_cover = decodeImage, .can_fetch_cover = canFetchCover };
    defer session.covers.deinit(gpa);
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
    defer session.cancelCoverJob();
    engine.launched() catch |err| std.log.warn("launch upkeep: {s}", .{@errorName(err)});
    try session.reloadLibrary();
    try session.migrateProgress();
    session.browser.ensure_network = connectNetwork;
    // Load the private, glibc2.23 image closure before InkView chooses its
    // C++ runtime. Both must resolve a compatible libstdc++ in one process.
    const image_tmp = try gpa.printSentinel("{s}/cache/image-tmp", .{root}, 0);
    try std.Io.Dir.cwd().createDirPath(io, image_tmp);
    if (setenv("TMPDIR", image_tmp, 1) != 0) return error.ImageTemporaryDirectoryFailed;
    const codec_path = init.minimal.environ.getPosix("POCKETMANGA_IMAGE_LIBRARY") orelse try std.fs.path.join(gpa, &.{ root, "runtime/image/lib/libpocketmanga-image.so" });
    var image_codecs = Vips.Library.load(codec_path) catch |err| {
        std.log.err("Cannot load image runtime {s}: {s}", .{ codec_path, @errorName(err) });
        return err;
    };
    defer image_codecs.deinit();
    codecs = &image_codecs;
    defer codecs = null;
    const region_cache = try std.fs.path.join(gpa, &.{ root, "cache/regions" });
    var region_service: Regions.Service = undefined;
    region_service.init(gpa, &image_codecs, region_cache);
    defer region_service.deinit();
    session.region_service = &region_service;
    defer session.clearRegionImage();
    const library_name = std.c.getenv("INKVIEW_LIBRARY") orelse "libinkview.so";
    var image_library = try std.DynLib.open(std.mem.span(library_name));
    network_connect = image_library.lookup(@TypeOf(network_connect), "NetConnect") orelse return error.MissingNetworkApi;
    power_guard.guard = @import("power.zig").Guard.load(&image_library);
    session.activity = updatePower;
    defer power_guard.guard.update(false, 0);
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
        .task_activity = updateTaskPower,
        // The PB629 preventor holds until stopped. Older expiring sleep bans
        // still need fallback ticks to renew protection during long decodes.
        .task_poll_interval_ms = if (power_guard.guard.persistent()) null else 100,
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

var power_guard: @import("power.zig").Activity = .{};
fn updatePower(active: bool) void {
    power_guard.updateOnline(active, tachi.worker.tachi_now_ms());
}
fn updateTaskPower(active: bool) void {
    power_guard.updateTasks(active, tachi.worker.tachi_now_ms());
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
        if (lifecycle_session) |session| {
            session.cancelCoverJob();
            if (session.browser.busy) |job| job.cancel();
        }
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
