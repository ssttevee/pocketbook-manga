//! Firmware-test diagnostic: drives libtachi's engine and worker as the app
//! does, from the packaged UI binary, and checks each step.
const std = @import("std");
const tachi = @import("tachi");
pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const root = it.next() orelse return error.MissingBundleRoot;
    const cmd = it.next() orelse "sources";
    var device_io = @import("device_io.zig").DeviceIo.init(init.io);
    try run(init.gpa, device_io.io(), init.minimal.environ, root, cmd, it.next());
}

fn now() u64 {
    return tachi.worker.tachi_now_ms();
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, root: []const u8, cmd: []const u8, package: ?[]const u8) !void {
    try checkIo(gpa, io, root);
    try checkUiMappings(gpa, io);
    std.debug.print("UI alone RSS: {d} KiB; no worker started.\n", .{tachi.worker.tachi_rss_kib()});
    const worker_exe = try std.fs.path.join(gpa, &.{ root, "bin/pocketmanga-worker" });
    var worker: tachi.worker.Client = undefined;
    try worker.init(gpa, io, .{ .exe = worker_exe, .args = &.{ "--serve", root }, .wrapper = environ.getPosix("POCKETMANGA_WORKER_EMULATOR") });
    defer worker.deinit();
    var engine: tachi.Engine = .init(gpa, io, worker.backend(), .{ .dir = root, .ca_file = try std.fs.path.join(gpa, &.{ root, "runtime/ca.pem" }) });
    const request: tachi.engine.Request = if (std.mem.eql(u8, cmd, "repo")) .{ .extensions = .{} } else if (std.mem.eql(u8, cmd, "install")) .{ .install = .{ .pkg = package orelse return error.MissingPackage } } else .sources;
    const canceled_start = try tachi.Job.start(&engine, request);
    if (canceled_start.phase.load(.acquire) != .starting) return error.MissingStartupPhase;
    const cancel_start = now();
    canceled_start.cancel();
    if (now() - cancel_start > 500 or worker.alive()) return error.StartupCancelNotImmediate;
    canceled_start.deinit();
    std.debug.print("Cold worker startup phase cancels immediately and reaps its child.\n", .{});
    const job = try runJob(&engine, request);
    defer job.deinit();
    if (!worker.workerReady() or job.phase.load(.acquire) != .operation) return error.MissingWorkerReady;
    const warm = try tachi.Job.start(&engine, .sources);
    if (warm.phase.load(.acquire) != .operation) return error.WarmWorkerStartupPhase;
    warm.join();
    if (warm.failure != null) return error.WarmWorkerFailed;
    warm.deinit();
    std.debug.print("Worker ready after JVM/extension restore; warm requests skip startup.\n", .{});
    std.debug.print("ARM JNI host: {d} installed sources, {d} repository extensions\n", .{ job.result.sources.len, job.result.extensions.len });
    if (environ.getPosix("POCKETMANGA_PARENT_EXIT_TEST") != null) {
        const path = try std.fmt.allocPrint(gpa, "{s}/.worker-pid", .{root});
        const pid = try std.fmt.allocPrint(gpa, "{d}", .{worker.workerPid()});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = pid });
        // Deliberately bypass normal UI cleanup to exercise EOF/PDEATHSIG.
        std.c._exit(0);
    }
    if (std.mem.eql(u8, cmd, "fixture")) try fixture(gpa, io, environ, &engine, &worker, package orelse return error.MissingFixture);
    std.debug.print("Worker RSS at completion: {d} KiB.\n", .{worker.last_rss_kib.load(.acquire)});
    if (environ.getPosix("POCKETMANGA_WORKER_TEST") != null) {
        worker.test_crash_next = true;
        const crashed = try tachi.Job.start(&engine, .sources);
        crashed.join();
        if (crashed.failure == null or !std.mem.eql(u8, crashed.failure.?, "WorkerCrashed")) return error.CrashNotReported;
        crashed.deinit();
        const retry = try runJob(&engine, .sources);
        retry.deinit();
        std.debug.print("Worker crash reported; retry restarted it successfully.\n", .{});
        try tachi.worker.send(worker.fd, gpa, tachi.worker.Command{ .version = tachi.worker.version + 1, .id = 9999, .kind = .cancel });
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const rejected = try tachi.worker.receive(tachi.worker.Response, worker.fd, arena.allocator());
        if (rejected.kind != .failure or rejected.id != 9999) return error.VersionNotRejected;
        std.debug.print("Worker rejects unsupported protocol versions.\n", .{});
        try worker.testEof();
        const after_eof = try runJob(&engine, .sources);
        after_eof.deinit();
        std.debug.print("Worker exits on pipe EOF; next request starts a fresh worker.\n", .{});
        if (environ.getPosix("POCKETMANGA_WORKER_IDLE_MS") != null) {
            try worker.testIdle();
            const after_idle = try runJob(&engine, .sources);
            after_idle.deinit();
            std.debug.print("Idle worker exits and is reaped; next request restarts it.\n", .{});
        }
    }
    worker.shutdown();
    try checkUiMappings(gpa, io);
}

/// The fixture extension end to end: install, search, add, download natively
/// with the worker released, and the extension-loading phase on a fresh worker.
fn fixture(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, engine: *tachi.Engine, worker: *tachi.worker.Client, file: []const u8) !void {
    const installed = try runJob(engine, .{ .install_file = file });
    installed.deinit();
    const search: tachi.engine.Request = .{ .browse = .{ .source = 424242, .kind = .{ .search = .{ .query = "fixture" } } } };
    const titles = try runJob(engine, search);
    defer titles.deinit();
    if (titles.result.page.?.mangas.len != 1) return error.FixtureSearchFailed;
    const added = try runJob(engine, .{ .add = .{ .source = 424242, .manga = titles.result.page.?.mangas[0] } });
    defer added.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const library = try engine.loadLibrary(a);
    const chapter_id = library.manga[0].chapters[0].id;
    if (environ.getPosix("POCKETMANGA_FIXTURE_CANCEL_RESUME") != null) {
        const partial = try tachi.Job.start(engine, .{ .download = chapter_id });
        defer partial.deinit();
        const deadline = now() + 60_000;
        while (partial.pages_done.load(.acquire) < 1 and !partial.done.load(.acquire)) {
            if (now() > deadline) return error.CancelSetupTimedOut;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        try io.sleep(.fromMilliseconds(300), .awake);
        const before_cancel = now();
        partial.cancel();
        const cancel_ms = now() - before_cancel;
        if (cancel_ms > 500 or partial.failure == null or !std.mem.eql(u8, partial.failure.?, "Canceled") or partial.pages_done.load(.acquire) != 1) return error.CancelNotImmediate;
        std.debug.print("Native stalled-body cancel returned Canceled in {d} ms; completed page retained.\n", .{cancel_ms});
    }
    const downloaded = try runJob(engine, .{ .download = chapter_id });
    defer downloaded.deinit();
    if (downloaded.pages_done.load(.acquire) != 3 or downloaded.pages_total.load(.acquire) != 3) return error.MissingDownloadProgress;
    std.debug.print("Native download progress: 3/3; worker RSS {d} KiB.\n", .{worker.last_rss_kib.load(.acquire)});
    const ready = try engine.loadLibrary(a);
    const pages = ready.manga[0].chapters[0].pages;
    if (pages.len != 3) return error.FixtureDownloadFailed;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try engine.pagePath(a, pages[0]), a, .limited(2 << 20));
    if (!std.mem.startsWith(u8, bytes, "\x89PNG")) return error.FixtureNotPng;
    if (worker.workerPid() != -1) return error.WorkerRetainedDuringNativeDownload;
    std.debug.print("ARM extension install, search, details, chapters and authenticated image download passed ({d} bytes/page; native TLS, Referer and cookie; worker released).\n", .{bytes.len});
    // The download released the worker, so a fresh one loads the extension
    // lazily and reports it first.
    const again = try runJob(engine, search);
    var extension_buf: [64]u8 = undefined;
    const loaded = again.extensionLoading(&extension_buf);
    if (loaded.len == 0 or again.phase.load(.acquire) != .operation) return error.MissingExtensionLoadingPhase;
    std.debug.print("Extension loading reported as its own phase: {s}\n", .{loaded});
    again.deinit();
    if (environ.getPosix("POCKETMANGA_FIXTURE_CANCEL_RESUME") != null) std.debug.print("Native retry resumed completed pages and published chapter.\n", .{});
}

fn runJob(engine: *tachi.Engine, request: tachi.engine.Request) !*tachi.Job {
    const job = try tachi.Job.start(engine, request);
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
