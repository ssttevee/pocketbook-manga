//! JNI diagnostic shared by the probe and the packaged app's opt-in check.
const std = @import("std");
const online = @import("worker_engine.zig");
pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const root = it.next() orelse return error.MissingBundleRoot;
    const cmd = it.next() orelse "sources";
    var device_io = @import("device_io.zig").DeviceIo.init(init.io);
    if (std.mem.eql(u8, cmd, "plan")) return plan(init.gpa, device_io.io(), init.minimal.environ, root, &it);
    try run(init.gpa, device_io.io(), init.minimal.environ, root, cmd, it.next());
}

/// `plan <extension.jar> <source id> <chapter url>`: times a live image plan twice.
fn plan(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, root: []const u8, it: *std.process.Args.Iterator) !void {
    const jar = it.next() orelse return error.MissingPackage;
    const source = try std.fmt.parseInt(i64, it.next() orelse return error.MissingSource, 10);
    const chapter = it.next() orelse return error.MissingChapter;
    var engine: online.Engine = .{ .gpa = gpa, .io = io, .root = root, .environ = environ };
    const started = @import("worker_wire.zig").pm_now_ms();
    const job = try runJob(&engine, .sources);
    job.deinit();
    const rt = engine.runtime.?;
    defer rt.deinit();
    // "-" reuses what an earlier run installed, so the restore path is timed.
    if (!std.mem.eql(u8, jar, "-")) gpa.free(try rt.installExtension(jar));
    std.log.info("plan probe ready_ms={d}", .{@import("worker_wire.zig").pm_now_ms() - started});
    const args = try std.json.Stringify.valueAlloc(gpa, .{ .chapter = .{ .url = chapter, .name = "probe" } }, .{});
    defer gpa.free(args);
    for (0..2) |_| {
        const before = @import("worker_wire.zig").pm_now_ms();
        const json = try rt.call(source, "imageRequests", args);
        defer gpa.free(json);
        std.log.info("plan probe imageRequests_ms={d} bytes={d}", .{ @import("worker_wire.zig").pm_now_ms() - before, json.len });
    }
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, root: []const u8, cmd: []const u8, package: ?[]const u8) !void {
    try checkKernel(environ);
    try checkIo(gpa, io, root);
    var engine: online.Engine = .{ .gpa = gpa, .io = io, .root = root, .environ = environ };
    const request: online.Request = if (std.mem.eql(u8, cmd, "repo")) .extensions else if (std.mem.eql(u8, cmd, "install")) .{ .install = package orelse return error.MissingPackage } else .sources;
    const job = try online.Job.start(&engine, request);
    defer job.deinit();
    job.join();
    if (job.failure) |failure| {
        std.debug.print("{s}\n", .{failure});
        return error.RuntimeProbeFailed;
    }
    std.debug.print("ARM JNI host: {d} installed sources, {d} repository extensions\n", .{ job.result.sources.len, job.result.extensions.len });
    if (std.mem.eql(u8, cmd, "fixture")) {
        const file = package orelse return error.MissingFixture;
        const installed = try engine.runtime.?.installExtension(file);
        gpa.free(installed);
        const titles = try runJob(&engine, .{ .titles = .{ .source = 424242, .query = "fixture" } });
        defer titles.deinit();
        if (titles.result.titles.?.mangas.len != 1) return error.FixtureSearchFailed;
        const added = try runJob(&engine, .{ .add = .{ .source = 424242, .manga = titles.result.titles.?.mangas[0] } });
        defer added.deinit();
        const library_path = try std.fs.path.join(gpa, &.{ root, "library.json" });
        const library = try @import("library.zig").readJson(@import("library.zig").Library, gpa, io, library_path);
        defer library.deinit();
        const book = library.value.manga[0];
        const planned = try runJob(&engine, .{ .download = .{ .book = book, .chapter = book.chapters[0] } });
        defer planned.deinit();
        if (planned.result.image_requests.?.len != 3) return error.FixtureDownloadFailed;
        for (planned.result.image_requests.?) |image_request| {
            if (image_request.fallback != null or image_request.rates.len != 2) return error.FixtureNativePlanFailed;
            if (image_request.rates[0].spacingMs != 50 or image_request.rates[1].spacingMs != 34) return error.FixtureRateExportFailed;
            const page_json = try std.json.Stringify.valueAlloc(gpa, image_request.page, .{});
            defer gpa.free(page_json);
            const image = try engine.runtime.?.fetchImage(424242, page_json);
            defer image.deinit(gpa);
            if (!std.mem.startsWith(u8, image.bytes, "\x89PNG")) return error.FixtureNotPng;
        }
        std.debug.print("ARM extension request plan, Referer/cookie and JVM image fallback passed.\n", .{});
    }
    try checkMappings(gpa, io, root);
    // Destroying the VM also verifies its main thread was detached correctly.
    if (engine.runtime) |rt| rt.deinit();
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

pub fn checkMappings(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const maps = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/maps", gpa, .limited(8 << 20));
    defer gpa.free(maps);
    const library_path = try std.fmt.allocPrint(gpa, "{s}/runtime/lib", .{root});
    defer gpa.free(library_path);
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, library_path, gpa);
    defer gpa.free(resolved);
    const bundled = try std.fmt.allocPrint(gpa, "{s}/", .{resolved});
    defer gpa.free(bundled);
    var found_libc = false;
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        const slash = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        const path = line[slash..];
        const name = std.fs.path.basename(path);
        const gnu = std.mem.startsWith(u8, name, "libc.so") or
            std.mem.startsWith(u8, name, "libc-2.") or
            std.mem.startsWith(u8, name, "ld-linux") or std.mem.startsWith(u8, name, "ld-2.") or
            std.mem.startsWith(u8, name, "libpthread") or std.mem.startsWith(u8, name, "libdl.") or
            std.mem.startsWith(u8, name, "libm.") or std.mem.startsWith(u8, name, "librt.") or
            std.mem.startsWith(u8, name, "libresolv") or std.mem.startsWith(u8, name, "libnss_dns") or
            std.mem.startsWith(u8, name, "libnss_files") or std.mem.startsWith(u8, name, "libstdc++") or
            std.mem.startsWith(u8, name, "libgcc_s") or std.mem.startsWith(u8, name, "libatomic");
        if (!gnu) continue;
        if (!std.mem.startsWith(u8, path, bundled)) {
            std.debug.print("Unexpected GNU runtime mapping: {s}\n", .{path});
            return error.MixedRuntime;
        }
        if (std.mem.eql(u8, name, "libc.so.6")) found_libc = true;
    }
    if (!found_libc) return error.BundledLibcNotMapped;
    std.debug.print("Bundled glibc mappings verified (no firmware glibc/toolchain in process).\n", .{});
}

pub fn checkKernel(environ: std.process.Environ) !void {
    if (environ.getPosix("POCKETMANGA_EXPECT_ENOSYS") != null) {
        var stat: std.os.linux.Statx = undefined;
        var byte: [1]u8 = undefined;
        if (std.os.linux.errno(std.os.linux.statx(std.os.linux.AT.FDCWD, "/", 0, .{ .TYPE = true }, &stat)) != .NOSYS or
            std.os.linux.errno(std.os.linux.getrandom(&byte, 1, 0)) != .NOSYS) return error.SyscallFilterIneffective;
        std.debug.print("Raw ARM statx and getrandom return ENOSYS.\n", .{});
    }
}
