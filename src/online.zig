//! Background UI requests. Java and libtachi live only in the child worker.
const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const lib = @import("library.zig");
pub const Request = protocol.Request;
pub const Result = protocol.Result;
pub const Phase = enum(u8) { operation, worker_starting, extension_loading };
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    engine: *Engine,
    request: Request,
    result: Result = .{},
    failure: ?[]const u8 = null,
    future: ?Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.operation),
    // Nested JVM image requests report their phase on the owning download job.
    status_owner: ?*Job = null,
    // The extension named while `phase` is `.extension_loading`.
    extension_lock: std.atomic.Mutex = .unlocked,
    extension_buf: [64]u8 = undefined,
    extension_len: usize = 0,
    // Spawn to ready, when this job had to start the worker.
    worker_start_ms: u64 = 0,
    pages_done: std.atomic.Value(usize) = .init(0),
    pages_total: std.atomic.Value(usize) = .init(0),
    pub fn start(engine: *Engine, request: Request) !*Job {
        if (engine.paused.load(.acquire)) return error.WorkerStopped;
        engine.client.interrupted.store(false, .release);
        const job = try engine.gpa.create(Job);
        errdefer engine.gpa.destroy(job);
        job.* = .{ .arena = .init(engine.gpa), .engine = engine, .request = undefined };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        const json = try std.json.Stringify.valueAlloc(a, request, .{});
        job.request = try std.json.parseFromSliceLeaky(Request, a, json, .{ .allocate = .alloc_always });
        if (request != .scan and engine.execute_fn == null) {
            try engine.client.prepare(engine);
            if (!engine.client.ready.load(.acquire)) job.setPhase(.worker_starting);
        }
        job.future = try engine.io.concurrent(run, .{job});
        return job;
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        const execute = self.engine.execute_fn orelse Engine.execute;
        execute(self.engine, self) catch |err| {
            if (self.failure == null) self.failure = std.fmt.allocPrint(self.arena.allocator(), "{s}", .{@errorName(err)}) catch "Operation failed (out of memory)";
            if (!@import("builtin").is_test) std.log.warn("{s}", .{self.failure.?});
        };
    }
    pub fn setPhase(self: *Job, phase: Phase) void {
        (self.status_owner orelse self).phase.store(phase, .release);
    }
    pub fn setExtensionLoading(self: *Job, name: []const u8) void {
        const owner = self.status_owner orelse self;
        while (!owner.extension_lock.tryLock()) std.atomic.spinLoopHint();
        const n = @min(name.len, owner.extension_buf.len);
        @memcpy(owner.extension_buf[0..n], name[0..n]);
        owner.extension_len = n;
        owner.extension_lock.unlock();
        owner.phase.store(.extension_loading, .release);
    }
    /// Copies the extension being loaded into `buf`.
    pub fn extensionLoading(self: *Job, buf: []u8) []const u8 {
        while (!self.extension_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.extension_lock.unlock();
        const n = @min(self.extension_len, buf.len);
        @memcpy(buf[0..n], self.extension_buf[0..n]);
        return buf[0..n];
    }
    pub fn checkCancelled(self: *Job) !void {
        try self.engine.io.checkCancel();
    }
    pub fn cancel(self: *Job) void {
        if (self.future) |*future| future.cancel(self.engine.io);
        // Cancellation may arrive before run installs its IPC cleanup.
        if (self.engine.execute_fn == null and self.request != .scan) self.engine.client.close();
    }
    pub fn join(self: *Job) void {
        // Forks must stay on the event thread. A challenge may need a fresh worker
        // after the planning worker has exited; tests use this same service loop.
        while (!self.done.load(.acquire)) {
            self.engine.serviceWorker();
            self.engine.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
        if (self.future) |*future| future.await(self.engine.io);
    }
    pub fn deinit(self: *Job) void {
        self.join();
        const gpa = self.engine.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,
    environ: std.process.Environ = .empty,
    execute_fn: ?*const fn (*Engine, *Job) anyerror!void = null,
    worker_needed: std.atomic.Value(bool) = .init(false),
    worker_ready: Io.Event = .unset,
    worker_failure: bool = false,
    paused: std.atomic.Value(bool) = .init(false),
    client: @import("worker_client.zig").Client = .{},

    pub fn serviceWorker(self: *Engine) void {
        if (!self.worker_needed.swap(false, .acq_rel)) return;
        self.worker_failure = false;
        self.client.prepare(self) catch {
            self.worker_failure = true;
        };
        self.worker_ready.set(self.io);
    }
    pub fn requireWorker(self: *Engine) !void {
        if (self.client.alive()) return;
        self.worker_ready.reset();
        self.worker_needed.store(true, .release);
        defer self.worker_needed.store(false, .release);
        try self.worker_ready.wait(self.io);
        if (self.worker_failure) return error.WorkerStartFailed;
    }
    pub fn execute(self: *Engine, job: *Job) !void {
        const a = job.arena.allocator();
        try job.checkCancelled();
        if (job.request == .scan) {
            const indexed = try @import("local.zig").scan(a, self.io, self.root);
            const path = try std.fs.path.join(a, &.{ self.root, "library.json" });
            const parsed = lib.readJson(lib.Library, a, self.io, path) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            var library: lib.Library = if (parsed) |p| p.value else .{};
            for (indexed.manga) |m| library = try @import("catalog.zig").merge(a, library, m);
            try lib.validate(library);
            try lib.writeJson(a, self.io, path, library);
            job.result = .{ .library_changed = true, .message = "Local manga indexed" };
            return;
        }
        if (job.request == .download) return @import("downloads.zig").download(self, job);
        try self.client.execute(self, job);
    }
    // Lifecycle shutdown interrupts the worker and cancels the active Io task
    // before descriptors can be reused by a subsequent request.
    pub fn interrupt(self: *Engine) void {
        self.paused.store(true, .release);
        self.client.interrupt();
    }
    pub fn deinit(self: *Engine) void {
        self.client.close();
    }
};
