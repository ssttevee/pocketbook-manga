//! Worker diagnostics: timing probes against live sources, and the checks
//! the firmware tests run inside the worker.
const std = @import("std");
const tachi = @import("tachi");

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const root = it.next() orelse return error.MissingBundleRoot;
    const cmd = it.next() orelse return error.MissingCommand;
    var device_io = @import("device_io.zig").DeviceIo.init(init.io);
    const io = device_io.io();
    var runtime: tachi.backend.InProcess = .init(init.gpa, io, try @import("worker.zig").runtimeOptions(init.gpa, root, init.minimal.environ));
    defer runtime.deinit();
    var engine: tachi.Engine = .init(init.gpa, io, runtime.backend(), .{ .dir = root, .ca_file = try std.fs.path.join(init.gpa, &.{ root, "runtime/ca.pem" }) });
    if (std.mem.eql(u8, cmd, "add")) return add(&engine, &runtime, &it);
    if (std.mem.eql(u8, cmd, "plan")) return plan(&engine, &runtime, &it);
    return error.UnknownCommand;
}

/// `add <extension.jar|-> <source id> <manga url>`: times adding a title, as Browse does.
fn add(engine: *tachi.Engine, runtime: *tachi.backend.InProcess, it: *std.process.Args.Iterator) !void {
    const jar = it.next() orelse return error.MissingPackage;
    const source = try std.fmt.parseInt(i64, it.next() orelse return error.MissingSource, 10);
    const url = it.next() orelse return error.MissingManga;
    const rt = try runtime.runtime();
    if (!std.mem.eql(u8, jar, "-")) engine.gpa.free(try rt.installExtension(jar));
    const before = tachi.worker.tachi_now_ms();
    const job = try runJob(engine, .{ .add = .{ .source = source, .manga = .{ .url = url, .title = "probe" } } });
    defer job.deinit();
    var arena: std.heap.ArenaAllocator = .init(engine.gpa);
    defer arena.deinit();
    const library = try engine.loadLibrary(arena.allocator());
    const m = library.manga[library.find(job.result.manga_id.?).?];
    std.log.info("add probe chapters={d} title={s} ms={d} rss_kib={d}", .{ m.chapters.len, m.title, tachi.worker.tachi_now_ms() - before, tachi.worker.tachi_rss_kib() });
}

/// `plan <extension.jar|-> <source id> <chapter url>`: times a live image plan twice.
fn plan(engine: *tachi.Engine, runtime: *tachi.backend.InProcess, it: *std.process.Args.Iterator) !void {
    const jar = it.next() orelse return error.MissingPackage;
    const source = try std.fmt.parseInt(i64, it.next() orelse return error.MissingSource, 10);
    const chapter = it.next() orelse return error.MissingChapter;
    const started = tachi.worker.tachi_now_ms();
    const rt = try runtime.runtime();
    // "-" reuses what an earlier run installed, so the restore path is timed.
    if (!std.mem.eql(u8, jar, "-")) engine.gpa.free(try rt.installExtension(jar));
    std.log.info("plan probe ready_ms={d}", .{tachi.worker.tachi_now_ms() - started});
    for (0..2) |_| {
        const before = tachi.worker.tachi_now_ms();
        const result = try rt.imageRequests(source, .{ .url = chapter, .name = "probe" });
        defer result.deinit();
        std.log.info("plan probe imageRequests_ms={d} pages={d}", .{ tachi.worker.tachi_now_ms() - before, result.value().len });
    }
}

fn runJob(engine: *tachi.Engine, request: tachi.engine.Request) !*tachi.Job {
    const job = try tachi.Job.start(engine, request);
    errdefer job.deinit();
    job.join();
    if (job.failure) |failure| {
        std.debug.print("{s}\n", .{failure});
        return error.ProbeFailed;
    }
    return job;
}

/// The worker runs on the reader's own C library: no GNU runtime library is
/// mapped from the app, and the JVM is the bundled one.
pub fn checkMappings(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const maps = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/maps", gpa, .limited(8 << 20));
    defer gpa.free(maps);
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, root, gpa);
    defer gpa.free(resolved);
    const app = try std.fmt.allocPrint(gpa, "{s}/", .{resolved});
    defer gpa.free(app);
    const jre = try std.fmt.allocPrint(gpa, "{s}runtime/jre/", .{app});
    defer gpa.free(jre);
    var found_libc = false;
    var found_jvm = false;
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        const slash = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        const path = line[slash..];
        const name = std.fs.path.basename(path);
        if (std.mem.eql(u8, name, "libjvm.so")) {
            if (!std.mem.startsWith(u8, path, jre)) {
                std.debug.print("Unexpected JVM mapping: {s}\n", .{path});
                return error.ForeignJvm;
            }
            found_jvm = true;
        }
        const gnu = std.mem.startsWith(u8, name, "libc.so") or
            std.mem.startsWith(u8, name, "libc-2.") or
            std.mem.startsWith(u8, name, "ld-linux") or std.mem.startsWith(u8, name, "ld-2.") or
            std.mem.startsWith(u8, name, "libpthread") or std.mem.startsWith(u8, name, "libdl.") or
            std.mem.startsWith(u8, name, "libdl-") or std.mem.startsWith(u8, name, "libm.") or
            std.mem.startsWith(u8, name, "libm-") or std.mem.startsWith(u8, name, "librt.") or
            std.mem.startsWith(u8, name, "librt-") or std.mem.startsWith(u8, name, "libresolv") or
            std.mem.startsWith(u8, name, "libnss_") or std.mem.startsWith(u8, name, "libstdc++") or
            std.mem.startsWith(u8, name, "libgcc_s") or std.mem.startsWith(u8, name, "libatomic");
        if (!gnu) continue;
        if (std.mem.startsWith(u8, path, app)) {
            std.debug.print("Unexpected bundled GNU runtime mapping: {s}\n", .{path});
            return error.BundledRuntime;
        }
        if (std.mem.startsWith(u8, name, "libc.so") or std.mem.startsWith(u8, name, "libc-2.")) found_libc = true;
    }
    if (!found_libc) return error.SystemLibcNotMapped;
    if (!found_jvm) return error.JvmNotMapped;
    std.debug.print("Worker mappings verified (reader's glibc, bundled JVM).\n", .{});
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
