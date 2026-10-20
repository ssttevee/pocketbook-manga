//! The worker process: libtachi's worker loop over a runtime in this process,
//! configured from the app bundle. No InkView or UI imports.
const std = @import("std");
const tachi = @import("tachi");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    if (!std.mem.eql(u8, mode, "--serve")) return @import("worker_probe.zig").main(init);
    const root = args.next() orelse return error.MissingRoot;
    const env = init.minimal.environ;
    try @import("worker_probe.zig").checkKernel(env);
    var device_io = @import("device_io.zig").DeviceIo.init(init.io);
    var runtime: tachi.backend.InProcess = .init(init.gpa, device_io.io(), try runtimeOptions(init.gpa, root, env));
    const testing = env.getPosix("POCKETMANGA_WORKER_TEST") != null;
    mapping_check = .{ .gpa = init.gpa, .io = device_io.io(), .root = root };
    tachi.worker.serve(init.gpa, &runtime, .{
        .idle_exit_ms = if (env.getPosix("POCKETMANGA_WORKER_IDLE_MS")) |text| try std.fmt.parseInt(u64, text, 10) else 60_000,
        .testing = testing,
        .after_call = if (testing) checkMappings else null,
    });
}

/// The bundle's runtime: its JRE, host jar and CA roots, with extension data
/// in `extensions/`. JVM sizing suits the Verse's 512 MB.
pub fn runtimeOptions(gpa: std.mem.Allocator, root: []const u8, environ: std.process.Environ) !tachi.Options {
    const trust = try std.fmt.allocPrint(gpa, "-Djavax.net.ssl.trustStore={s}/runtime/jre/lib/security/cacerts", .{root});
    const options = try gpa.dupe([]const u8, &.{ "-Xms16m", "-Xmx128m", "-Xss512k", "-XX:MaxMetaspaceSize=96m", "-XX:+UseSerialGC", "-XX:ActiveProcessorCount=2", trust });
    return .{
        .data_dir = try std.fs.path.join(gpa, &.{ root, "extensions" }),
        .host_jar = try std.fs.path.join(gpa, &.{ root, "runtime/tachi-host.jar" }),
        .java_home = try std.fs.path.join(gpa, &.{ root, "runtime/jre" }),
        .ca_file = try std.fs.path.join(gpa, &.{ root, "runtime/ca.pem" }),
        .native_transport = true,
        .environ = environ,
        .jvm_options = options,
    };
}

var mapping_check: struct { gpa: std.mem.Allocator, io: std.Io, root: []const u8 } = undefined;

fn checkMappings() void {
    @import("worker_probe.zig").checkMappings(mapping_check.gpa, mapping_check.io, mapping_check.root) catch |err| {
        std.debug.print("Worker mapping check failed: {s}\n", .{@errorName(err)});
        std.c._exit(71);
    };
}
