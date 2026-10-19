//! Background UI requests. Java and libtachi live only in the child worker.
const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const lib = @import("library.zig");
pub const Request = protocol.Request;
pub const Result = protocol.Result;
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    engine: *Engine,
    request: Request,
    result: Result = .{},
    failure: ?[]const u8 = null,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    pages_done: std.atomic.Value(usize) = .init(0),
    pages_total: std.atomic.Value(usize) = .init(0),
    pub fn start(engine: *Engine, request: Request) !*Job {
        if (engine.paused.load(.acquire)) return error.WorkerStopped;
        engine.client.interrupted.store(false, .release);
        if (request != .scan and engine.execute_fn == null) try engine.client.prepare(engine);
        const job = try engine.gpa.create(Job);
        errdefer engine.gpa.destroy(job);
        job.* = .{ .arena = .init(engine.gpa), .engine = engine, .request = undefined };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        const json = try std.json.Stringify.valueAlloc(a, request, .{});
        job.request = try std.json.parseFromSliceLeaky(Request, a, json, .{ .allocate = .alloc_always });
        job.thread = try .spawn(.{}, run, .{job});
        return job;
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        const execute = self.engine.execute_fn orelse Engine.execute;
        execute(self.engine, self) catch |err| {
            self.failure = std.fmt.allocPrint(self.arena.allocator(), "{s}", .{@errorName(err)}) catch "Operation failed (out of memory)";
            if (!@import("builtin").is_test) std.log.warn("{s}", .{self.failure.?});
        };
    }
    pub fn checkCancelled(self: *Job) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }
    pub fn join(self: *Job) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
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
    paused: std.atomic.Value(bool) = .init(false),
    client: @import("worker_client.zig").Client = .{},

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
        try self.client.execute(self, job);
    }
    // Interrupt first, join the UI's request thread, then close/reap. The
    // worker socket cannot be recycled while a request still reads it.
    pub fn interrupt(self: *Engine) void {
        self.paused.store(true, .release);
        self.client.interrupt();
    }
    pub fn deinit(self: *Engine) void {
        self.client.close();
    }
};
