//! Serialized background libtachi operations. No UI/model pointers cross threads.
const std = @import("std");
const Io = std.Io;
const tachi = @import("tachi");
const lib = @import("library.zig");
const catalog = @import("catalog.zig");
const local = @import("local.zig");
const protocol = @import("protocol.zig");
const models = @import("source_models.zig");
const wire = @import("worker_wire.zig");
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
    runtime_ready: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    pages_done: std.atomic.Value(usize) = .init(0),
    pages_total: std.atomic.Value(usize) = .init(0),
    pub fn start(engine: *Engine, request: Request) !*Job {
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
        tachi.setLastError("");
        defer if (self.engine.runtime) |rt| rt.detachThread();
        const execute = self.engine.execute_fn orelse Engine.execute;
        execute(self.engine, self) catch |err| {
            self.failure = std.fmt.allocPrint(self.arena.allocator(), "{s}: {s}", .{ @errorName(err), tachi.lastError() }) catch "Operation failed (out of memory)";
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
    runtime: ?*tachi.Runtime = null,
    attempted_runtime: bool = false,
    // Injectable executor for deterministic UI/thread tests without network or Java.
    execute_fn: ?*const fn (*Engine, *Job) anyerror!void = null,
    // Optional overrides are for local runtime diagnostics; the device uses its bundle.
    java_home: ?[]const u8 = null,
    host_jar: ?[]const u8 = null,

    fn initRuntime(self: *Engine) !*tachi.Runtime {
        if (self.runtime) |rt| return rt;
        if (self.attempted_runtime) return error.RuntimeStartupFailedRestartApp;
        self.attempted_runtime = true;
        const a = self.gpa;
        const data = try std.fs.path.join(a, &.{ self.root, "extensions" });
        defer a.free(data);
        const jar = try std.fs.path.join(a, &.{ self.root, "runtime/tachi-host.jar" });
        defer a.free(jar);
        const home = try std.fs.path.join(a, &.{ self.root, "runtime/jre" });
        defer a.free(home);
        const ca = try std.fs.path.join(a, &.{ self.root, "runtime/ca.pem" });
        defer a.free(ca);
        const trust = try std.fmt.allocPrint(a, "-Djavax.net.ssl.trustStore={s}/runtime/jre/lib/security/cacerts", .{self.root});
        defer a.free(trust);
        const started = wire.pm_now_ms();
        const rt = try tachi.Runtime.init(a, self.io, .{
            .data_dir = data,
            .host_jar = self.host_jar orelse jar,
            .java_home = self.java_home orelse home,
            .ca_file = if (self.java_home != null) null else ca,
            .class_data_sharing = false,
            .native_transport = true,
            .environ = self.environ,
            .jvm_options = &.{ "-Xms16m", "-Xmx128m", "-Xss512k", "-XX:MaxMetaspaceSize=96m", "-XX:+UseSerialGC", "-XX:ActiveProcessorCount=2", trust },
        });
        // Never attempt to recreate HotSpot in this process, even if restore fails.
        self.runtime = rt;
        const jvm_ready = wire.pm_now_ms();
        const restored = try rt.restore();
        std.log.info("worker runtime jvm_ms={d} restore_ms={d}", .{ jvm_ready - started, wire.pm_now_ms() - jvm_ready });
        defer a.free(restored);
        const report = try std.json.parseFromSlice(tachi.manage.RestoreResult, a, restored, models.parse_options);
        defer report.deinit();
        for (report.value.failed) |failure| std.log.warn("Extension restore {s}: {s}", .{ failure.pkg, failure.@"error" });
        return rt;
    }
    pub fn execute(self: *Engine, job: *Job) !void {
        const a = job.arena.allocator();
        try job.checkCancelled();
        if (job.request == .scan) {
            const indexed = try local.scan(a, self.io, self.root);
            var library = try self.readLibrary(a);
            for (indexed.manga) |m| library = try catalog.merge(a, library, m);
            try self.saveLibrary(a, library);
            job.result = .{ .library_changed = true, .message = "Local manga indexed" };
            return;
        }
        const rt = try self.initRuntime();
        job.runtime_ready.store(true, .release);
        switch (job.request) {
            .sources => try self.sources(job),
            .extensions => job.result.extensions = try parse([]const protocol.RepoEntry, a, try std.json.Stringify.valueAlloc(a, try rt.repoList(a, .{}), .{})),
            .install_file => |file| {
                const installed = try rt.installExtension(file);
                self.gpa.free(installed);
                try self.sources(job);
            },
            .install => |pkg| {
                const json = try rt.repoInstall(pkg, .{});
                defer self.gpa.free(json);
                try self.sources(job);
                job.result.message = "Extension installed";
            },
            .uninstall => |pkg| {
                _ = try rt.uninstallExtension(pkg);
                try self.sources(job);
                job.result.message = "Extension removed";
            },
            .titles => |request| {
                const args = try std.json.Stringify.valueAlloc(a, .{ .page = request.page, .query = request.query }, .{});
                const method: []const u8 = if (request.query.len > 0) "search" else if (request.latest) "latest" else "popular";
                const json = try rt.call(request.source, method, args);
                defer self.gpa.free(json);
                job.result.titles = try parse(models.MangasPage, a, json);
            },
            .add => |request| {
                const manga = try self.refreshBook(job, request.source, request.manga);
                job.result.open_id = manga.id;
                job.result.library_changed = true;
                job.result.message = "Added to library";
            },
            .refresh => |book| {
                _ = try self.refreshBook(job, book.source_id orelse return error.LocalTitle, book.remote orelse return error.LocalTitle);
                job.result.library_changed = true;
                job.result.message = "Chapter list updated";
            },
            .update_all => {
                const library = try self.readLibrary(a);
                for (library.manga) |book| {
                    try job.checkCancelled();
                    if (book.source_id) |id| if (book.remote) |manga| {
                        _ = try self.refreshBook(job, id, manga);
                        job.result.library_changed = true;
                    };
                }
                job.result.message = "Library updated";
            },
            .download => |request| try self.planDownload(job, request.book, request.chapter),
            .benchmark => |request| {
                if (self.environ.getPosix("POCKETMANGA_WORKER_TEST") == null) return error.DiagnosticsDisabled;
                const source = request.book.source_id orelse return error.LocalTitle;
                const args = try std.json.Stringify.valueAlloc(a, .{ .chapter = request.chapter.remote.? }, .{});
                const json = try rt.call(source, "pages", args);
                defer self.gpa.free(json);
                const pages = try parse([]const models.Page, a, json);
                const started = wire.pm_now_ms();
                var total: usize = 0;
                for (pages, 0..) |page, i| {
                    const before = wire.pm_now_ms();
                    const page_json = try std.json.Stringify.valueAlloc(a, page, .{});
                    const image = try rt.fetchImage(source, page_json);
                    defer image.deinit(self.gpa);
                    total += image.bytes.len;
                    std.log.info("JVM benchmark page {d}/{d} bytes={d} network_ms={d}", .{ i + 1, pages.len, image.bytes.len, wire.pm_now_ms() - before });
                }
                std.log.info("JVM benchmark chapter pages={d} bytes={d} network_ms={d}", .{ pages.len, total, wire.pm_now_ms() - started });
            },
            .image => |request| {
                if (request.cookies.len > 0) {
                    const cookie_args = try std.json.Stringify.valueAlloc(a, .{ .url = request.url, .cookies = request.cookies }, .{});
                    const restored = try rt.call(request.source, "imageCookies", cookie_args);
                    self.gpa.free(restored);
                }
                const page_json = try std.json.Stringify.valueAlloc(a, request.page, .{});
                const image = try rt.fetchImage(request.source, page_json);
                defer image.deinit(self.gpa);
                if (image.bytes.len > 16 << 20) return error.ImageTooLarge;
                const encoder = std.base64.standard.Encoder;
                const encoded = try a.alloc(u8, encoder.calcSize(image.bytes.len));
                job.result.image_base64 = encoder.encode(encoded, image.bytes);
            },
            .preferences => |id| try self.preferences(job, id),
            .set_preference => |request| {
                const args = try std.json.Stringify.valueAlloc(a, .{ .key = request.key, .value = request.value }, .{});
                const json = try rt.call(request.source, "setPreference", args);
                self.gpa.free(json);
                try self.preferences(job, request.source);
                job.result.message = "Source setting saved";
            },
            .scan => unreachable,
        }
    }
    fn sources(self: *Engine, job: *Job) !void {
        const a = job.arena.allocator();
        const json = try self.runtime.?.listExtensions();
        defer self.gpa.free(json);
        const extensions = try parse([]const models.ExtensionInfo, a, json);
        var sources_list: std.ArrayList(models.SourceInfo) = .empty;
        for (extensions) |ext| try sources_list.appendSlice(a, ext.sources);
        job.result.sources = sources_list.items;
    }
    fn preferences(self: *Engine, job: *Job, id: i64) !void {
        const json = try self.runtime.?.call(id, "preferences", "{}");
        defer self.gpa.free(json);
        job.result.preferences = try parse([]const models.Preference, job.arena.allocator(), json);
    }
    fn readLibrary(self: *Engine, a: std.mem.Allocator) !lib.Library {
        const path = try std.fs.path.join(a, &.{ self.root, "library.json" });
        const parsed = lib.readJson(lib.Library, a, self.io, path) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        try lib.validate(parsed.value);
        return parsed.value;
    }
    fn saveLibrary(self: *Engine, a: std.mem.Allocator, library: lib.Library) !void {
        try lib.validate(library);
        const path = try std.fs.path.join(a, &.{ self.root, "library.json" });
        try lib.writeJson(a, self.io, path, library);
    }
    fn refreshBook(self: *Engine, job: *Job, id: i64, manga: models.Manga) !lib.Manga {
        const a = job.arena.allocator();
        const args = try std.json.Stringify.valueAlloc(a, .{ .manga = manga }, .{});
        const detail_json = try self.runtime.?.call(id, "details", args);
        defer self.gpa.free(detail_json);
        const details = try parse(models.Manga, a, detail_json);
        const chapter_args = try std.json.Stringify.valueAlloc(a, .{ .manga = details }, .{});
        const chapter_json = try self.runtime.?.call(id, "chapters", chapter_args);
        defer self.gpa.free(chapter_json);
        const chapters = try parse([]const models.Chapter, a, chapter_json);
        const list = try a.alloc(lib.Chapter, chapters.len);
        for (chapters, list) |ch, *dst| dst.* = .{ .id = try std.fmt.allocPrint(a, "{d}:{s}", .{ id, ch.url }), .title = ch.name, .remote = ch };
        const book: lib.Manga = .{
            .id = try std.fmt.allocPrint(a, "{d}:{s}", .{ id, manga.url }),
            .title = details.title,
            .author = details.author orelse "",
            .description = details.description orelse "",
            .chapters = list,
            .source_id = id,
            .remote = details,
        };
        try job.checkCancelled();
        try self.saveLibrary(a, try catalog.merge(a, try self.readLibrary(a), book));
        return book;
    }
    fn planDownload(self: *Engine, job: *Job, book: lib.Manga, chapter: lib.Chapter) !void {
        const a = job.arena.allocator();
        const id = book.source_id orelse return error.LocalTitle;
        const remote = chapter.remote orelse return error.MissingChapterMetadata;
        const args = try std.json.Stringify.valueAlloc(a, .{ .chapter = remote }, .{});
        const json = try self.runtime.?.call(id, "imageRequests", args);
        defer self.gpa.free(json);
        job.result.image_requests = try parse([]const protocol.ImageRequest, a, json);
    }
};
fn parse(comptime T: type, a: std.mem.Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, json, models.parse_options);
}
