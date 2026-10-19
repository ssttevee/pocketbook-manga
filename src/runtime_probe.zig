//! JNI diagnostic shared by the probe and the packaged app's opt-in check.
const std = @import("std");
const online = @import("online.zig");
pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const root = it.next() orelse return error.MissingBundleRoot;
    const cmd = it.next() orelse "sources";
    var device_io = @import("device_io.zig").DeviceIo.init(init.io);
    try run(init.gpa, device_io.io(), init.minimal.environ, root, cmd, it.next());
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, root: []const u8, cmd: []const u8, package: ?[]const u8) !void {
    try checkIo(gpa, io, root);
    try checkUiMappings(gpa, io);
    std.debug.print("UI alone RSS: {d} KiB; no worker started.\n", .{@import("worker_wire.zig").pm_rss_kib()});
    var engine: online.Engine = .{ .gpa = gpa, .io = io, .root = root, .environ = environ };
    defer engine.deinit();
    const request: online.Request = if (std.mem.eql(u8, cmd, "repo")) .extensions else if (std.mem.eql(u8, cmd, "install")) .{ .install = package orelse return error.MissingPackage } else .sources;
    const canceled_start = try online.Job.start(&engine, request);
    if (canceled_start.phase.load(.acquire) != .worker_starting) return error.MissingStartupPhase;
    const cancel_start = @import("worker_wire.zig").pm_now_ms();
    canceled_start.cancel();
    if (@import("worker_wire.zig").pm_now_ms() - cancel_start > 500 or engine.client.alive()) return error.StartupCancelNotImmediate;
    canceled_start.deinit();
    std.debug.print("Cold worker startup phase cancels immediately and reaps its child.\n", .{});
    const job = try online.Job.start(&engine, request);
    defer job.deinit();
    job.join();
    if (job.failure) |failure| {
        std.debug.print("{s}\n", .{failure});
        return error.RuntimeProbeFailed;
    }
    if (!engine.client.ready.load(.acquire) or job.phase.load(.acquire) != .operation) return error.MissingWorkerReady;
    const warm = try online.Job.start(&engine, .sources);
    if (warm.phase.load(.acquire) != .operation) return error.WarmWorkerStartupPhase;
    warm.join();
    if (warm.failure != null) return error.WarmWorkerFailed;
    warm.deinit();
    std.debug.print("Worker ready after JVM/extension restore; warm requests skip startup.\n", .{});
    std.debug.print("ARM JNI host: {d} installed sources, {d} repository extensions\n", .{ job.result.sources.len, job.result.extensions.len });
    if (environ.getPosix("POCKETMANGA_PARENT_EXIT_TEST") != null) {
        const path = try std.fmt.allocPrint(gpa, "{s}/.worker-pid", .{root});
        const pid = try std.fmt.allocPrint(gpa, "{d}", .{engine.client.pid});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = pid });
        // Deliberately bypass normal UI cleanup to exercise EOF/PDEATHSIG.
        std.c._exit(0);
    }
    if (std.mem.eql(u8, cmd, "fixture")) {
        const file = package orelse return error.MissingFixture;
        const installed = try runJob(&engine, .{ .install_file = file });
        installed.deinit();
        const titles = try runJob(&engine, .{ .titles = .{ .source = 424242, .query = "fixture" } });
        defer titles.deinit();
        if (titles.result.titles.?.mangas.len != 1) return error.FixtureSearchFailed;
        const added = try runJob(&engine, .{ .add = .{ .source = 424242, .manga = titles.result.titles.?.mangas[0] } });
        defer added.deinit();
        const library_path = try std.fs.path.join(gpa, &.{ root, "library.json" });
        const library = try @import("library.zig").readJson(@import("library.zig").Library, gpa, io, library_path);
        defer library.deinit();
        const book = library.value.manga[0];
        if (environ.getPosix("POCKETMANGA_FIXTURE_CANCEL_RESUME") != null) {
            const partial = try online.Job.start(&engine, .{ .download = .{ .book = book, .chapter = book.chapters[0] } });
            defer partial.deinit();
            const deadline = @import("worker_wire.zig").pm_now_ms() + 60_000;
            while (partial.pages_done.load(.acquire) < 1 and !partial.done.load(.acquire)) {
                if (@import("worker_wire.zig").pm_now_ms() > deadline) return error.CancelSetupTimedOut;
                try io.sleep(.fromMilliseconds(10), .awake);
            }
            try io.sleep(.fromMilliseconds(300), .awake);
            const before_cancel = @import("worker_wire.zig").pm_now_ms();
            partial.cancel();
            const cancel_ms = @import("worker_wire.zig").pm_now_ms() - before_cancel;
            if (cancel_ms > 500 or partial.failure == null or !std.mem.eql(u8, partial.failure.?, "Canceled") or partial.pages_done.load(.acquire) != 1) return error.CancelNotImmediate;
            std.debug.print("Native stalled-body cancel returned Canceled in {d} ms; completed page retained.\n", .{cancel_ms});
        }
        const downloaded = try runJob(&engine, .{ .download = .{ .book = book, .chapter = book.chapters[0] } });
        defer downloaded.deinit();
        if (downloaded.pages_done.load(.acquire) != 3 or downloaded.pages_total.load(.acquire) != 3) return error.MissingDownloadProgress;
        std.debug.print("Native download progress: 3/3; worker RSS {d} KiB.\n", .{engine.client.last_rss_kib});
        const ready = try @import("library.zig").readJson(@import("library.zig").Library, gpa, io, library_path);
        defer ready.deinit();
        if (ready.value.manga[0].chapters[0].pages.len != 3) return error.FixtureDownloadFailed;
        const page_path = try std.fs.path.join(gpa, &.{ root, ready.value.manga[0].chapters[0].pages[0] });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, page_path, gpa, .limited(2 << 20));
        defer gpa.free(bytes);
        if (!std.mem.startsWith(u8, bytes, "\x89PNG")) return error.FixtureNotPng;
        if (engine.client.pid != -1) return error.WorkerRetainedDuringNativeDownload;
        std.debug.print("ARM extension install, search, details, chapters and authenticated image download passed ({d} bytes/page; native TLS, Referer and cookie; worker released).\n", .{bytes.len});
        const benchmark = try runJob(&engine, .{ .benchmark = .{ .book = book, .chapter = book.chapters[0] } });
        benchmark.deinit();
        if (environ.getPosix("POCKETMANGA_FIXTURE_CANCEL_RESUME") != null) std.debug.print("Native retry resumed completed pages and published chapter.\n", .{});
    }
    std.debug.print("Worker RSS at completion: {d} KiB.\n", .{engine.client.last_rss_kib});
    if (environ.getPosix("POCKETMANGA_WORKER_TEST") != null) {
        engine.client.test_crash_next = true;
        const crashed = try online.Job.start(&engine, .sources);
        crashed.join();
        if (crashed.failure == null or !std.mem.eql(u8, crashed.failure.?, "WorkerCrashed")) return error.CrashNotReported;
        crashed.deinit();
        const retry = try runJob(&engine, .sources);
        retry.deinit();
        std.debug.print("Worker crash reported; retry restarted it successfully.\n", .{});
        const wire = @import("worker_wire.zig");
        const p = @import("protocol.zig");
        try wire.send(engine.client.fd, gpa, p.Command{ .version = p.version + 1, .id = 9999, .kind = .cancel });
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const rejected = try wire.receive(p.Response, engine.client.fd, arena.allocator());
        if (rejected.kind != .failure or rejected.id != 9999) return error.VersionNotRejected;
        std.debug.print("Worker rejects unsupported protocol versions.\n", .{});
        try engine.client.testEof();
        const after_eof = try runJob(&engine, .sources);
        after_eof.deinit();
        std.debug.print("Worker exits on pipe EOF; next request starts a fresh worker.\n", .{});
        if (environ.getPosix("POCKETMANGA_WORKER_IDLE_MS") != null) {
            try engine.client.testIdle();
            const after_idle = try runJob(&engine, .sources);
            after_idle.deinit();
            std.debug.print("Idle worker exits and is reaped; next request restarts it.\n", .{});
        }
    }
    engine.client.shutdown(gpa);
    try checkUiMappings(gpa, io);
}

fn runJob(engine: *online.Engine, request: online.Request) !*online.Job {
    const job = try online.Job.start(engine, request);
    errdefer job.deinit();
    job.join();
    if (job.failure) |failure| {
        std.debug.print("{s}\n", .{failure});
        return error.RuntimeProbeFailed;
    }
    return job;
}

fn checkIo(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const path = try std.fs.path.join(gpa, &.{ root, ".runtime-check/nested" });
    defer gpa.free(path);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, path);
    try cwd.createDirPath(io, path);
    var dir = try cwd.openDir(io, path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "length", .data = "fixture" });
    const file = try dir.openFile(io, "length", .{});
    defer file.close(io);
    if (try file.length(io) != 7 or (try file.stat(io)).size != 7) return error.FileLengthCheckFailed;
    if ((try dir.statFile(io, "length", .{})).kind != .file) return error.StatCheckFailed;
    if (dir.createDirPath(io, "length")) |_| return error.FileAcceptedAsDirectory else |err| {
        if (err != error.NotDir) return err;
    }
    var child = try dir.createDirPathOpen(io, "created/child", .{});
    child.close(io);
    const bytes = try dir.readFileAlloc(io, "length", gpa, .limited(32));
    defer gpa.free(bytes);
    if (!std.mem.eql(u8, bytes, "fixture")) return error.ReadCheckFailed;
    var random: [32]u8 = undefined;
    try io.randomSecure(&random);
    if (std.mem.allEqual(u8, &random, 0)) return error.EntropyCheckFailed;
    std.debug.print("Linux file metadata, repeated mkdir and entropy passed.\n", .{});
}

fn checkUiMappings(gpa: std.mem.Allocator, io: std.Io) !void {
    const maps = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/maps", gpa, .limited(8 << 20));
    defer gpa.free(maps);
    if (std.mem.indexOf(u8, maps, "libjvm.so") != null or std.mem.indexOf(u8, maps, "/runtime/lib/") != null) return error.ForeignRuntimeInUi;
    std.debug.print("Native UI mappings verified: no JVM or bundled glibc in UI.\n", .{});
}
