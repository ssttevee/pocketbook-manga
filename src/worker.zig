//! Headless JNI/libtachi process; no InkView or UI imports.
const std = @import("std");
const online = @import("worker_engine.zig");
const p = @import("protocol.zig");
const wire = @import("worker_wire.zig");
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    if (!std.mem.eql(u8, mode, "--serve")) return @import("worker_probe.zig").main(init);
    const root = args.next() orelse return error.MissingRoot;
    try @import("worker_probe.zig").checkKernel(init.minimal.environ);
    var device_io = @import("device_io.zig").DeviceIo.init(init.io);
    var engine: online.Engine = .{ .gpa = init.gpa, .io = device_io.io(), .root = root, .environ = init.minimal.environ };
    const fd: c_int = 3;
    const idle_ms = if (init.minimal.environ.getPosix("POCKETMANGA_WORKER_IDLE_MS")) |text| try std.fmt.parseInt(u64, text, 10) else 60_000;
    var active: ?*online.Job = null;
    var id: u64 = 0;
    var last_activity = wire.pm_now_ms();
    var last_done: usize = 0;
    var last_total: usize = 0;
    var sent_ready = false;
    var sent_extension: online.ExtensionState = .none;
    while (true) {
        if (active) |job| {
            const done = job.pages_done.load(.acquire);
            const total = job.pages_total.load(.acquire);
            const finished = job.done.load(.acquire);
            if (!sent_ready and job.runtime_ready.load(.acquire)) {
                try wire.send(fd, init.gpa, p.Response{ .id = id, .kind = .ready });
                sent_ready = true;
            }
            const extension = job.extension_state.load(.acquire);
            if (extension != sent_extension) {
                try wire.send(fd, init.gpa, p.Response{ .id = id, .kind = .loading, .extension = if (extension == .loading) job.extension else null });
                sent_extension = extension;
            }
            if (done != last_done or total != last_total or finished) {
                try wire.send(fd, init.gpa, p.Response{ .id = id, .kind = .progress, .pages_done = done, .pages_total = total, .rss_kib = wire.pm_rss_kib() });
                last_done = done;
                last_total = total;
            }
            if (finished) {
                job.join();
                if (init.minimal.environ.getPosix("POCKETMANGA_WORKER_TEST") != null) try @import("worker_probe.zig").checkMappings(init.gpa, device_io.io(), root);
                try wire.send(fd, init.gpa, p.Response{ .id = id, .kind = if (job.failure != null) .failure else .result, .failure = job.failure, .result = if (job.failure == null) job.result else null, .pages_done = done, .pages_total = total, .rss_kib = wire.pm_rss_kib() });
                job.deinit();
                active = null;
                last_activity = wire.pm_now_ms();
            }
        } else if (wire.pm_now_ms() - last_activity >= idle_ms) std.c._exit(0);
        if (!try wire.ready(fd, 100)) continue;
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const command = wire.receive(p.Command, fd, arena.allocator()) catch std.c._exit(0); // EOF also stops in-flight HTTP immediately.
        if (command.version != p.version) {
            try wire.send(fd, init.gpa, p.Response{ .id = command.id, .kind = .failure, .failure = "Unsupported worker protocol version" });
            continue;
        }
        switch (command.kind) {
            .shutdown => std.c._exit(0),
            .cancel => if (active) |job| {
                if (command.id == id) {
                    job.cancelled.store(true, .release);
                    const source: ?i64 = switch (job.request) {
                        .download => |r| r.book.source_id,
                        .image => |r| r.source,
                        .titles => |r| r.source,
                        else => null,
                    };
                    if (source) |source_id| if (engine.runtime) |rt| {
                        const canceled = rt.call(source_id, "cancel", "{}") catch null;
                        if (canceled) |bytes| init.gpa.free(bytes);
                        rt.detachThread();
                    };
                    std.c._exit(0);
                }
            },
            .crash => {
                if (init.minimal.environ.getPosix("POCKETMANGA_WORKER_TEST") != null) std.c._exit(70);
                return error.InvalidCommand;
            },
            .request => {
                if (active != null) return error.ConcurrentWorkerRequest;
                id = command.id;
                last_done = 0;
                last_total = 0;
                sent_ready = false;
                sent_extension = .none;
                active = try online.Job.start(&engine, command.request orelse return error.MissingRequest);
            },
        }
    }
}
