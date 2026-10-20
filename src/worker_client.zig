//! One on-demand child, serialized by online.Job. The UI thread may interrupt
//! it at any time; descriptors close after the reading Io task has stopped.
const std = @import("std");
const online = @import("online.zig");
const p = @import("protocol.zig");
const wire = @import("worker_wire.zig");
extern "c" fn pm_spawn([*:0]const u8, [*:null]const ?[*:0]const u8, *c_int) c_int;
extern "c" fn pm_interrupt(c_int, c_int) void;
extern "c" fn pm_eof(c_int) void;
extern "c" fn pm_reap(c_int, c_int) c_int;
pub const Client = struct {
    mutex: std.atomic.Mutex = .unlocked,
    interrupted: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),
    pid: c_int = -1,
    spawned_ms: u64 = 0,
    fd: c_int = -1,
    next_id: u64 = 1,
    test_crash_next: bool = false,
    last_rss_kib: usize = 0,
    fn lock(self: *Client) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn alive(self: *Client) bool {
        self.lock();
        defer self.mutex.unlock();
        if (self.pid > 0 and pm_reap(self.pid, 0) != 0) {
            if (self.fd >= 0) _ = std.c.close(self.fd);
            self.fd = -1;
            self.pid = -1;
        }
        return self.pid > 0;
    }
    pub fn interrupt(self: *Client) void {
        self.interrupted.store(true, .release);
        self.lock();
        defer self.mutex.unlock();
        pm_interrupt(self.pid, self.fd);
    }
    pub fn close(self: *Client) void {
        self.lock();
        defer self.mutex.unlock();
        pm_interrupt(self.pid, self.fd);
        if (self.pid > 0) _ = pm_reap(self.pid, 1);
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.pid = -1;
        self.fd = -1;
        self.ready.store(false, .release);
    }
    fn waitExit(self: *Client) bool {
        return self.waitExitFor(1500);
    }
    fn waitExitFor(self: *Client, ms: u64) bool {
        const until = wire.pm_now_ms() + ms;
        while (self.pid > 0 and wire.pm_now_ms() < until) {
            if (pm_reap(self.pid, 0) != 0) {
                self.pid = -1;
                return true;
            }
            _ = wire.ready(self.fd, 20) catch false;
        }
        return self.pid <= 0;
    }
    pub fn shutdown(self: *Client, gpa: std.mem.Allocator) void {
        if (self.fd >= 0) wire.send(self.fd, gpa, p.Command{ .id = 0, .kind = .shutdown }) catch {};
        _ = self.waitExit();
        self.close();
    }
    pub fn testEof(self: *Client) !void {
        if (self.fd < 0) return error.NoWorker;
        pm_eof(self.fd);
        if (!self.waitExit()) return error.WorkerIgnoredEof;
        self.close();
    }
    pub fn testIdle(self: *Client) !void {
        if (!self.waitExit()) return error.WorkerIgnoredIdleTimeout;
        self.close();
    }
    fn ensure(self: *Client, engine: *online.Engine, a: std.mem.Allocator) !void {
        self.lock();
        defer self.mutex.unlock();
        if (self.interrupted.load(.acquire)) return error.WorkerStopped;
        if (self.pid > 0 and pm_reap(self.pid, 0) != 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
            self.pid = -1;
        }
        if (self.pid > 0) return;
        const loader = try std.fmt.allocPrintSentinel(a, "{s}/runtime/lib/ld-linux.so.3", .{engine.root}, 0);
        const binary = try std.fmt.allocPrintSentinel(a, "{s}/bin/pocketmanga-worker", .{engine.root}, 0);
        const root = try a.dupeSentinel(u8, engine.root, 0);
        const libraries = try std.fmt.allocPrintSentinel(a, "{s}/runtime/lib:{s}/runtime/jre/lib:{s}/runtime/jre/lib/server:/ebrmain/lib:/usr/lib:/ebrmain/cramfs/lib", .{ engine.root, engine.root, engine.root }, 0);
        const emulator = engine.environ.getPosix("POCKETMANGA_WORKER_EMULATOR");
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        if (emulator) |exe| try argv.append(a, (try a.dupeSentinel(u8, exe, 0)).ptr);
        try argv.appendSlice(a, &.{ loader.ptr, "--inhibit-cache", "--library-path", libraries.ptr, "--argv0", binary.ptr, binary.ptr, "--serve", root.ptr });
        try argv.append(a, null);
        self.ready.store(false, .release);
        self.spawned_ms = wire.pm_now_ms();
        self.pid = pm_spawn(argv.items[0].?, @ptrCast(argv.items.ptr), &self.fd);
        if (self.pid < 0) return error.WorkerStartFailed;
    }
    // Linux PDEATHSIG follows the thread that forks, so prepare is called
    // by Job.start on the long-lived UI thread, never its request thread.
    pub fn prepare(self: *Client, engine: *online.Engine) !void {
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        try self.ensure(engine, arena.allocator());
    }
    pub fn execute(self: *Client, engine: *online.Engine, job: *online.Job) !void {
        return self.call(engine, job, job.request);
    }
    pub fn call(self: *Client, engine: *online.Engine, job: *online.Job, request: p.Request) !void {
        if (!self.alive() or !self.ready.load(.acquire)) job.setPhase(.worker_starting);
        try engine.requireWorker();
        const a = job.arena.allocator();
        if (self.pid <= 0 or self.interrupted.load(.acquire)) return error.WorkerStopped;
        const id = self.next_id;
        self.next_id += 1;
        errdefer {
            wire.cancelNow(self.fd, id);
            _ = self.waitExitFor(75);
            // Stop the waiter through Io first; then terminate the uncooperative JNI
            // process. No outstanding frame is ever reused after cancellation.
            self.close();
        }
        const crash = self.test_crash_next;
        self.test_crash_next = false;
        try wire.sendIo(engine.io, self.fd, a, p.Command{ .id = id, .kind = if (crash) .crash else .request, .request = if (crash) null else request });
        while (true) {
            const response = try wire.receiveTimed(engine.io, self.fd, a);
            if (response.version != p.version or response.id != id) return error.WorkerProtocolMismatch;
            if (response.kind == .ready) {
                if (!self.ready.swap(true, .acq_rel)) {
                    job.worker_start_ms = wire.pm_now_ms() - self.spawned_ms;
                    std.log.info("worker ready startup_ms={d}", .{job.worker_start_ms});
                }
                job.setPhase(.operation);
                continue;
            }
            if (response.kind == .loading) {
                if (response.extension) |name| job.setExtensionLoading(name) else job.setPhase(.operation);
                continue;
            }
            job.pages_done.store(response.pages_done, .release);
            job.pages_total.store(response.pages_total, .release);
            self.last_rss_kib = response.rss_kib;
            switch (response.kind) {
                .ready, .loading => unreachable,
                .progress => {},
                .failure => {
                    job.failure = response.failure orelse "Worker failed";
                    return error.ExtensionFailure;
                },
                .result => {
                    job.result = response.result orelse return error.InvalidWorkerResult;
                    return;
                },
            }
        }
    }
};
