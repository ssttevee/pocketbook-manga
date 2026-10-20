//! All chapter storage and transfer policy lives here, independent of the reader.
//! One page at a time bounds memory, makes rate limiting conservative, and lets
//! Io.Future.cancel interrupt DNS/TLS/socket/file operations in the UI process.
const std = @import("std");
const Io = std.Io;
const p = @import("protocol.zig");
const lib = @import("library.zig");
const online = @import("online.zig");
const max_image = 16 << 20;

pub fn nativeEligible(request: p.ImageRequest) bool {
    return request.fallback == null and std.mem.eql(u8, request.method, "GET") and
        (std.mem.startsWith(u8, request.url, "https://") or std.mem.startsWith(u8, request.url, "http://"));
}

/// Evenly spaced dispatch is stricter than a permits/window burst. Initial wait
/// drains any host-side window used while resolving the chapter. Keys identify
/// the actual interceptor/rule, so a global rule is shared across image hosts.
pub const Limiter = struct {
    next: std.StringHashMap(i64),
    pub fn init(a: std.mem.Allocator) Limiter {
        return .{ .next = .init(a) };
    }
    pub fn deinit(self: *Limiter) void {
        self.next.deinit();
    }
    pub fn delay(self: *Limiter, rates: []const p.Rate, now: i64) !i64 {
        var until = now;
        for (rates) |rate| {
            if (rate.spacingMs == 0 or rate.initialWaitMs < rate.spacingMs or rate.initialWaitMs > std.math.maxInt(i32)) return error.InvalidRateLimit;
            const entry = try self.next.getOrPut(rate.key);
            if (!entry.found_existing) entry.value_ptr.* = now + @as(i64, @intCast(rate.initialWaitMs));
            until = @max(until, entry.value_ptr.*);
        }
        for (rates) |rate| self.next.getPtr(rate.key).?.* = until + @as(i64, @intCast(rate.spacingMs));
        return until - now;
    }
    fn wait(self: *Limiter, io: Io, rates: []const p.Rate) !void {
        const ms = try self.delay(rates, millis(io));
        if (ms > 0) try io.sleep(.fromMilliseconds(ms), .awake);
    }
};

/// Logical manifest paths are resolved here for both download and reading.
/// A future SD-card policy belongs here; local titles retain the app root.
pub fn pagePath(a: std.mem.Allocator, root: []const u8, relative_path: []const u8) ![:0]u8 {
    if (!lib.safePath(relative_path)) return error.UnsafePagePath;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, relative_path }, 0);
}

pub const Store = struct {
    a: std.mem.Allocator,
    io: Io,
    root: []const u8,
    folder: []const u8,
    pub fn init(a: std.mem.Allocator, io: Io, root: []const u8, chapter: []const u8, requests: []const p.ImageRequest) !Store {
        // Page URLs are stable when supplied. Otherwise use image filenames:
        // MangaDex rotates both its node and token path on every resolution.
        var identity = std.hash.Wyhash.init(0);
        identity.update(std.mem.asBytes(&requests.len));
        for (requests) |request| {
            identity.update(std.mem.asBytes(&request.page.index));
            identity.update(request.page.url);
            identity.update(&.{0});
            if (request.page.url.len == 0) {
                const image_url = request.page.imageUrl orelse request.url;
                const path = image_url[0 .. std.mem.indexOfAny(u8, image_url, "?#") orelse image_url.len];
                const filename = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidImageUrl) + 1 ..];
                if (filename.len == 0) return error.InvalidImageUrl;
                identity.update(filename);
            }
            identity.update(&.{0});
        }
        const folder = try std.fmt.allocPrint(a, "downloads/{x}/{x}", .{ std.hash.Wyhash.hash(0, chapter), identity.final() });
        const path = try pagePath(a, root, folder);
        try Io.Dir.cwd().createDirPath(io, path);
        return .{ .a = a, .io = io, .root = root, .folder = folder };
    }
    pub fn relative(self: Store, index: usize, ext: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{d:0>4}.{s}", .{ self.folder, index + 1, ext });
    }
    fn absolute(self: Store, relative_path: []const u8) ![]const u8 {
        return pagePath(self.a, self.root, relative_path);
    }
    pub fn complete(self: Store, index: usize) !?[]const u8 {
        for ([_][]const u8{ "png", "jpg" }) |ext| {
            const relative_path = try self.relative(index, ext);
            const path = try self.absolute(relative_path);
            const file = Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer file.close(self.io);
            var header: [8]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &header, 0);
            if (imageExtension(header[0..n])) |actual| {
                if (std.mem.eql(u8, actual, ext) and try file.length(self.io) > 8) return relative_path;
            }
        }
        return null;
    }
    fn temp(self: Store, index: usize) ![]const u8 {
        return self.absolute(try self.relative(index, "tmp"));
    }
    fn publish(self: Store, index: usize, ext: []const u8) ![]const u8 {
        const relative_path = try self.relative(index, ext);
        try Io.Dir.cwd().rename(try self.temp(index), Io.Dir.cwd(), try self.absolute(relative_path), self.io);
        return relative_path;
    }
    pub fn put(self: Store, index: usize, bytes: []const u8) ![]const u8 {
        const ext = imageExtension(bytes) orelse return error.UnsupportedImageFormat;
        const path = try self.temp(index);
        const file = try Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        try file.writePositionalAll(self.io, bytes, 0);
        try file.sync(self.io);
        return self.publish(index, ext);
    }
};
fn imageExtension(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "jpg";
    return null;
}
fn millis(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}
const Transfer = struct { path: []const u8, bytes: usize, network_ms: i64, disk_ms: i64, head_ms: i64 = 0 };

/// No automatic redirects: the next URL could need different jar cookies,
/// authentication or a host-specific rate rule. The source client handles it.
fn fetch(client: *std.http.Client, store: Store, index: usize, request: p.ImageRequest) !Transfer {
    const io = store.io;
    const started = millis(io);
    var bytes: usize = 0;
    var disk_ms: i64 = 0;
    var completed = false;
    defer if (!completed) {
        if (!@import("builtin").is_test) std.log.info("page {d} incomplete bytes_written={d} network_ms={d} disk_ms={d}", .{ index + 1, bytes, millis(io) - started - disk_ms, disk_ms });
    };
    var req = try client.request(.GET, try std.Uri.parse(request.url), .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .omit, .user_agent = .omit },
        // Redirects are unhandled, so these can never leak to another origin.
        // This Zig snapshot does not emit privileged_headers in sendHead.
        .extra_headers = request.headers,
    });
    defer req.deinit();
    req.sendBodiless() catch |err| return req.connection.?.stream_writer.err orelse err;
    var response = req.receiveHead(&.{}) catch |err| switch (err) {
        error.ReadFailed => return req.connection.?.getReadError().?,
        else => return err,
    };
    if (response.head.status.class() == .redirect) return error.JvmRedirect;
    if (response.head.status == .forbidden or response.head.status == .service_unavailable or response.head.status == .unauthorized) return error.JvmChallengeOrAuthentication;
    if (response.head.status.class() != .success) {
        std.log.warn("page {d} HTTP status {d}", .{ index + 1, @backingInt(response.head.status) });
        return error.HttpStatusFailure;
    }
    if (response.head.content_encoding != .identity) return error.JvmContentEncoding;
    if (response.head.content_length) |length| if (length > max_image) return error.ImageTooLarge;
    const head_ms = millis(io) - started;
    var buffer: [64 << 10]u8 = undefined;
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const temp_path = try store.temp(index);
    const file = try Io.Dir.cwd().createFile(io, temp_path, .{});
    defer file.close(io);
    var extension: ?[]const u8 = null;
    while (true) {
        const n = reader.readSliceShort(&buffer) catch {
            // HTTP framing can forward the connection's ReadFailed without
            // setting bodyErr. Preserve the underlying Io cancellation.
            if (response.bodyErr()) |err| return err;
            return req.connection.?.getReadError() orelse error.NetworkReadFailed;
        };
        if (n == 0) break;
        if (bytes == 0) extension = imageExtension(buffer[0..n]) orelse return error.JvmImageResponse;
        if (bytes + n > max_image) return error.ImageTooLarge;
        const disk_start = millis(io);
        try file.writePositionalAll(io, buffer[0..n], bytes);
        disk_ms += millis(io) - disk_start;
        bytes += n;
    }
    if (bytes <= 8) return error.EmptyImage;
    const disk_start = millis(io);
    try file.sync(io);
    const path = try store.publish(index, extension orelse return error.EmptyImage);
    disk_ms += millis(io) - disk_start;
    completed = true;
    return .{ .path = path, .bytes = bytes, .network_ms = millis(io) - started - disk_ms, .disk_ms = disk_ms, .head_ms = head_ms };
}

fn pageDeadline(io: Io) Io.Cancelable!void {
    try io.sleep(.fromSeconds(120), .awake);
}
fn fetchTimed(client: *std.http.Client, store: Store, index: usize, request: p.ImageRequest) !Transfer {
    const Result = union(enum) { transfer: anyerror!Transfer, deadline: Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select: Io.Select(Result) = .init(store.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.transfer, fetch, .{ client, store, index, request });
    try select.concurrent(.deadline, pageDeadline, .{store.io});
    return switch (try select.await()) {
        .transfer => |result| result,
        .deadline => |result| {
            try result;
            return error.PageTimedOut;
        },
    };
}

pub fn download(engine: *online.Engine, job: *online.Job) !void {
    const a = job.arena.allocator();
    const io = engine.io;
    const request = job.request.download;
    const chapter_started = millis(io);
    const source = request.book.source_id orelse return error.LocalTitle;
    try engine.client.call(engine, job, job.request);
    const requests = job.result.image_requests orelse return error.InvalidImagePlan;
    const planning_ms = millis(io) - chapter_started;
    if (requests.len == 0) return error.EmptyChapter;
    // Release the JVM before native transfer. Dynamic fallbacks request a new
    // worker through the event thread, preserving PDEATHSIG thread ownership.
    var retain_worker = false;
    for (requests) |image_request| if (!nativeEligible(image_request)) {
        retain_worker = true;
    };
    if (!retain_worker) engine.client.close();
    defer engine.client.close();
    job.result = .{};
    job.pages_total.store(requests.len, .release);
    const store = try Store.init(a, io, engine.root, request.chapter.id, requests);
    const paths = try a.alloc([]const u8, requests.len);
    var client: std.http.Client = .{ .allocator = engine.gpa, .io = io };
    defer client.deinit();
    const ca = try std.fs.path.join(a, &.{ engine.root, "runtime/ca.pem" });
    const now = Io.Clock.real.now(io);
    // Tests using local HTTP need no PEM, but HTTPS never uses a system fallback.
    var ca_loaded = false;
    var limiter = Limiter.init(a);
    defer limiter.deinit();
    const started = millis(io);
    var total_bytes: usize = 0;
    var network_ms: i64 = 0;
    var disk_ms: i64 = 0;
    var skipped: usize = 0;
    var native_pages: usize = 0;
    defer std.log.info("chapter pages={d}/{d} resumed={d} native={d} bytes={d} network_ms={d} disk_ms={d} elapsed_ms={d} planning_ms={d} worker_start_ms={d} total_elapsed_ms={d}", .{ job.pages_done.load(.acquire), requests.len, skipped, native_pages, total_bytes, network_ms, disk_ms, millis(io) - started, planning_ms, job.worker_start_ms, millis(io) - chapter_started });
    for (requests, 0..) |image_request, i| {
        try io.checkCancel();
        if (try store.complete(i)) |path| {
            paths[i] = path;
            skipped += 1;
        } else {
            try limiter.wait(io, image_request.rates);
            var transfer: ?Transfer = null;
            var fallback_reason = image_request.fallback orelse "unsupported URI or method";
            if (nativeEligible(image_request)) {
                if (!ca_loaded and std.mem.startsWith(u8, image_request.url, "https://")) {
                    try client.ca_bundle.addCertsFromFilePath(engine.gpa, io, now, Io.Dir.cwd(), ca);
                    client.now = now;
                    ca_loaded = true;
                }
                transfer = fetchTimed(&client, store, i, image_request) catch |err| switch (err) {
                    error.JvmRedirect, error.JvmChallengeOrAuthentication, error.JvmContentEncoding, error.JvmImageResponse => blk: {
                        fallback_reason = @errorName(err);
                        break :blk null;
                    },
                    else => return err,
                };
                if (transfer != null) native_pages += 1;
            }
            if (transfer == null) {
                std.log.info("page {d}/{d} JVM fallback: {s}", .{ i + 1, requests.len, fallback_reason });
                // Native dispatches are not in OkHttp's window. Drain that window
                // before switching clients; drain it again before returning native.
                var drain: u64 = 0;
                for (image_request.rates) |rate| drain = @max(drain, rate.initialWaitMs);
                if (drain > 0) try io.sleep(.fromMilliseconds(@intCast(drain)), .awake);
                const network_start = millis(io);
                var fallback_job: online.Job = .{ .arena = .init(engine.gpa), .engine = engine, .request = .{ .image = .{ .source = source, .page = image_request.page, .url = image_request.url, .cookies = image_request.cookies } }, .phase_target = &job.phase };
                defer fallback_job.arena.deinit();
                engine.client.call(engine, &fallback_job, fallback_job.request) catch |err| {
                    if (fallback_job.failure) |failure| job.failure = try a.dupe(u8, failure);
                    return err;
                };
                const encoded = fallback_job.result.image_base64 orelse return error.InvalidImageResponse;
                const decoder = std.base64.standard.Decoder;
                const bytes = try fallback_job.arena.allocator().alloc(u8, try decoder.calcSizeForSlice(encoded));
                try decoder.decode(bytes, encoded);
                const disk_start = millis(io);
                const path = try store.put(i, bytes);
                transfer = .{ .path = path, .bytes = bytes.len, .network_ms = disk_start - network_start, .disk_ms = millis(io) - disk_start };
                if (!retain_worker) engine.client.close();
                if (drain > 0) try io.sleep(.fromMilliseconds(@intCast(drain)), .awake);
                job.result = .{};
            }
            const t = transfer.?;
            paths[i] = t.path;
            total_bytes += t.bytes;
            network_ms += t.network_ms;
            disk_ms += t.disk_ms;
            std.log.info("page {d}/{d} bytes={d} network_ms={d} head_ms={d} body_ms={d} disk_ms={d}", .{ i + 1, requests.len, t.bytes, t.network_ms, t.head_ms, t.network_ms - t.head_ms, t.disk_ms });
        }
        job.pages_done.store(i + 1, .release);
    }
    try io.checkCancel();
    const library_path = try std.fs.path.join(a, &.{ engine.root, "library.json" });
    const library = try lib.readJson(lib.Library, a, io, library_path);
    var chapter = request.chapter;
    chapter.pages = paths;
    var book = request.book;
    book.chapters = &.{chapter};
    const merged = try @import("catalog.zig").merge(a, library.value, book);
    try lib.validate(merged);
    try lib.writeJson(a, io, library_path, merged);
    job.result = .{ .library_changed = true, .open_id = book.id, .message = "Chapter downloaded" };
}

test "fallback decision never bypasses non-GETs or extension transforms" {
    const t = std.testing;
    var request: p.ImageRequest = .{ .page = .{ .index = 0 }, .url = "https://test/image", .method = "GET", .headers = &.{} };
    try t.expect(nativeEligible(request));
    request.method = "POST";
    try t.expect(!nativeEligible(request));
    request.method = "GET";
    request.fallback = "descrambler interceptor";
    try t.expect(!nativeEligible(request));
    request.fallback = null;
    request.url = "data:image/png;base64,...";
    try t.expect(!nativeEligible(request));
}

test "rate limiter drains JVM windows and spaces a shared rule across hosts" {
    var limiter = Limiter.init(std.testing.allocator);
    defer limiter.deinit();
    const rates: []const p.Rate = &.{.{ .key = "global", .spacingMs = 250, .initialWaitMs = 1000 }};
    try std.testing.expectEqual(1000, try limiter.delay(rates, 0));
    try std.testing.expectEqual(1150, try limiter.delay(rates, 100));
    try std.testing.expectEqual(0, try limiter.delay(rates, 2000));
    try std.testing.expectEqual(250, try limiter.delay(rates, 2000));
}

test "partial pages survive failure and cancel; retry skips only completed pages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();
    const root = try temp_dir.dir.realPathFileAlloc(io, ".", a);
    const plan: []const p.ImageRequest = &.{.{ .page = .{ .index = 0, .imageUrl = "http://test/page" }, .url = "http://test/page", .method = "GET", .headers = &.{} }};
    const store = try Store.init(a, io, root, "chapter", plan);
    const png = "\x89PNG\r\n\x1a\ncompleted-page";
    const first = try store.put(0, png);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try store.temp(1), .data = "truncated" });
    const retry = try Store.init(a, io, root, "chapter", plan);
    try std.testing.expectEqualStrings(first, (try retry.complete(0)).?);
    try std.testing.expect(try retry.complete(1) == null);
    var renewed = plan[0];
    renewed.page.imageUrl = "http://test/page?renewed-token";
    const renewed_store = try Store.init(a, io, root, "chapter", &.{renewed});
    try std.testing.expectEqualStrings(first, (try renewed_store.complete(0)).?);
    const changed = try Store.init(a, io, root, "different-chapter", plan);
    try std.testing.expect(try changed.complete(0) == null);
}

const StallServer = struct {
    io: Io,
    server: *Io.net.Server,
    sent: Io.Event = .unset,
    fn run(self: *StallServer) !void {
        const connection = try self.server.accept(self.io);
        defer connection.close(self.io);
        var writer = connection.writer(self.io, &.{});
        writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 200000\r\nContent-Type: image/png\r\n\r\n\x89PNG\r\n\x1a\n") catch return writer.err.?;
        self.sent.set(self.io);
        try self.io.sleep(.fromSeconds(60), .awake);
    }
};

test "cancel interrupts a stalled native body immediately and preserves completed pages" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var stall: StallServer = .{ .io = io, .server = &server };
    var serving = try io.concurrent(StallServer.run, .{&stall});
    defer _ = serving.cancel(io) catch {};
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/stall", .{server.socket.address.getPort()});
    const request: p.ImageRequest = .{ .page = .{ .index = 0 }, .url = url, .method = "GET", .headers = &.{} };
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const store = try Store.init(a, io, root, "chapter", &.{request});
    const completed = try store.put(0, "\x89PNG\r\n\x1a\ncomplete");
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var transfer = try io.concurrent(fetch, .{ &client, store, 1, request });
    defer _ = transfer.cancel(io) catch {};
    try stall.sent.wait(io);
    const started = millis(io);
    try std.testing.expectError(error.Canceled, transfer.cancel(io));
    try std.testing.expect(millis(io) - started < 500);
    try std.testing.expectEqualStrings(completed, (try store.complete(0)).?);
    try std.testing.expect(try store.complete(1) == null);
    // Retry replaces the incomplete temp file without losing the first page.
    _ = try store.put(1, "\x89PNG\r\n\x1a\nretry-complete");
    try std.testing.expect(try store.complete(1) != null);
}

test "IPC cancellation interrupts a partial frame through std.Io" {
    const io = std.testing.io;
    var handles: [2]c_int = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &handles) != 0) return error.SocketPairFailed;
    const address: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } };
    const sockets = [_]Io.net.Socket{ .{ .handle = handles[0], .address = address }, .{ .handle = handles[1], .address = address } };
    defer for (sockets) |socket| socket.close(io);
    const Receiver = struct {
        fn receive(inner_io: Io, fd: c_int) !p.Response {
            return @import("worker_wire.zig").receiveIo(p.Response, inner_io, fd, std.testing.allocator);
        }
    };
    var pending = try io.concurrent(Receiver.receive, .{ io, sockets[0].handle });
    defer _ = pending.cancel(io) catch {};
    var writer = (Io.net.Stream{ .socket = sockets[1] }).writer(io, &.{});
    try writer.interface.writeAll("\x10\x00");
    const started = millis(io);
    try std.testing.expectError(error.Canceled, pending.cancel(io));
    try std.testing.expect(millis(io) - started < 500);
}

test "MangaDex resume ignores node and token but detects changed filenames, order and count" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const old: p.ImageRequest = .{ .page = .{ .index = 0, .imageUrl = "https://old.mangadex.network/old-token/data/hash/001-content.jpg?old#fragment" }, .url = "https://old.mangadex.network/old-token/data/hash/001-content.jpg", .method = "GET", .headers = &.{} };
    var renewed = old;
    renewed.page.imageUrl = "https://new.mangadex.network/new-token/data/hash/001-content.jpg?new#other";
    renewed.url = renewed.page.imageUrl.?;
    const store = try Store.init(a, io, root, "chapter", &.{old});
    const path = try store.put(0, "\x89PNG\r\n\x1a\ncompleted-image");
    const retry = try Store.init(a, io, root, "chapter", &.{renewed});
    try std.testing.expectEqualStrings(path, (try retry.complete(0)).?);
    var changed = renewed;
    changed.page.imageUrl = "https://new.mangadex.network/token/data/hash/replaced-content.jpg";
    const replaced = try Store.init(a, io, root, "chapter", &.{changed});
    try std.testing.expect(try replaced.complete(0) == null);
    changed = renewed;
    changed.page.index = 1;
    const reordered = try Store.init(a, io, root, "chapter", &.{changed});
    try std.testing.expect(try reordered.complete(0) == null);
    const longer = try Store.init(a, io, root, "chapter", &.{ renewed, changed });
    try std.testing.expect(try longer.complete(0) == null);
    var stable = old;
    stable.page.url = "/stable/page/1";
    const stable_store = try Store.init(a, io, root, "stable", &.{stable});
    stable.page.imageUrl = changed.page.imageUrl;
    const stable_retry = try Store.init(a, io, root, "stable", &.{stable});
    try std.testing.expectEqualStrings(stable_store.folder, stable_retry.folder);
    stable.page.url = "/stable/page/2";
    const stable_changed = try Store.init(a, io, root, "stable", &.{stable});
    try std.testing.expect(!std.mem.eql(u8, stable_store.folder, stable_changed.folder));
}
