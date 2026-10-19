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
    const job = try online.Job.start(&engine, request);
    defer job.deinit();
    job.join();
    if (job.failure) |failure| {
        std.debug.print("{s}\n", .{failure});
        return error.RuntimeProbeFailed;
    }
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
        const downloaded = try runJob(&engine, .{ .download = .{ .book = book, .chapter = book.chapters[0] } });
        defer downloaded.deinit();
        if (downloaded.pages_done.load(.acquire) != 1 or downloaded.pages_total.load(.acquire) != 1) return error.MissingDownloadProgress;
        std.debug.print("Download progress crossed protocol: 1/1; worker RSS {d} KiB.\n", .{engine.client.last_rss_kib});
        const ready = try @import("library.zig").readJson(@import("library.zig").Library, gpa, io, library_path);
        defer ready.deinit();
        if (ready.value.manga[0].chapters[0].pages.len != 1) return error.FixtureDownloadFailed;
        const page_path = try std.fs.path.join(gpa, &.{ root, ready.value.manga[0].chapters[0].pages[0] });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, page_path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        if (!std.mem.startsWith(u8, bytes, "\x89PNG")) return error.FixtureNotPng;
        std.debug.print("ARM extension install, search, details, chapters and authenticated image download passed ({d} bytes).\n", .{bytes.len});
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
