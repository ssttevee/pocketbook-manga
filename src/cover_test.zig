const std = @import("std");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Image = @import("reader-image");

fn thumbnail(session: *Session, path: []const u8, width: usize, height: usize) !Image {
    try std.testing.expectEqual(160, width);
    try std.testing.expectEqual(240, height);
    if (std.mem.eql(u8, path, "missing.png")) return error.FileNotFound;
    if (std.mem.eql(u8, path, "broken.png")) return error.ImageDecodeFailed;
    const pixels = try session.model.gpa.alloc(u8, 4);
    @memset(pixels, 127);
    return .{ .width = 2, .height = 2, .pixels = pixels, .revision = std.hash.Wyhash.hash(0, path) };
}

test "cover decoding preserves reader image and missing or unsafe covers are placeholders" {
    var model: lib.Model = .{ .gpa = std.testing.allocator };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = ".", .load_cover = thumbnail };
    defer session.deinit();
    const page = [_]u8{ 1, 2, 3, 4 };
    session.image = .{ .width = 2, .height = 2, .pixels = &page, .revision = 17 };
    session.beginCoverFrame();
    const manga: lib.Manga = .{ .id = "story", .title = "Story", .cover = "covers/story.png" };
    const cover = session.coverImage(manga).?;
    try std.testing.expectEqual(127, cover.pixels[0]);
    try std.testing.expectEqualSlices(u8, &page, session.image.?.pixels);
    try std.testing.expectEqual(17, session.image.?.revision);
    try std.testing.expect(session.coverImage(.{ .id = "missing", .title = "Missing" }) == null);
    try std.testing.expect(session.coverImage(.{ .id = "absent", .title = "Absent", .cover = "missing.png" }) == null);
    try std.testing.expect(session.coverImage(.{ .id = "unsafe", .title = "Unsafe", .cover = "../outside.png" }) == null);
    try std.testing.expect(session.coverImage(.{ .id = "broken", .title = "Broken", .cover = "broken.png" }) == null);
}

test {
    _ = @import("covers.zig");
}

const tachi = @import("tachi");
const remote_manga: lib.Manga = .{
    .id = "42:/story",
    .title = "Remote Story",
    .source_id = 42,
    .remote = .{ .url = "/story", .title = "Remote Story", .thumbnailUrl = "https://fixture/cover.png" },
};
var requests: std.atomic.Value(usize) = .init(0);
var canceled: std.atomic.Value(bool) = .init(false);

fn cacheCover(engine: *tachi.Engine, job: *tachi.Job) !void {
    _ = requests.fetchAdd(1, .monotonic);
    try std.testing.expectEqualStrings("https://fixture/cover.png", job.request.cover.url);
    const path = try std.fmt.allocPrint(job.arena.allocator(), "{s}/covers/{x}.png", .{ engine.options.dir, std.hash.Wyhash.hash(0, job.request.cover.url) });
    try std.Io.Dir.cwd().createDirPath(engine.io, std.fs.path.dirname(path).?);
    const file = try std.Io.Dir.cwd().createFile(engine.io, path, .{});
    defer file.close(engine.io);
    try file.writeStreamingAll(engine.io, "fixture");
}

fn failCover(_: *tachi.Engine, _: *tachi.Job) !void {
    _ = requests.fetchAdd(1, .monotonic);
    return error.NetworkUnavailable;
}

fn cancelCover(engine: *tachi.Engine, job: *tachi.Job) !void {
    if (job.request != .cover) return;
    _ = requests.fetchAdd(1, .monotonic);
    defer canceled.store(true, .release);
    while (true) try engine.io.sleep(.fromMilliseconds(1), .awake);
}

test "remote cover request owns its inputs and completes without foreground busy state" {
    requests.store(0, .monotonic);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var engine: tachi.Engine = .init(gpa, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.deinit();
    engine.execute_fn = cacheCover;
    var model: lib.Model = .{ .gpa = gpa };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root, .load_cover = thumbnail };
    session.browser.engine = &engine;
    defer session.deinit();
    session.setStatus("Ready");
    var url = "https://fixture/cover.png".*;
    var manga = remote_manga;
    manga.remote.?.thumbnailUrl = &url;
    try std.testing.expect(session.coverImage(manga) == null);
    @memset(&url, 'x');
    try std.testing.expect(session.cover_job != null);
    try std.testing.expect(session.browser.busy == null);
    session.cover_job.?.join();
    try session.poll();
    try std.testing.expect(session.cover_job == null);
    try std.testing.expect(session.coverImage(remote_manga) != null);
    try std.testing.expectEqualStrings("Ready", session.status);
    try std.testing.expectEqual(1, requests.load(.monotonic));
}

test "failed optional remote artwork stays a placeholder without retrying each frame" {
    requests.store(0, .monotonic);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var engine: tachi.Engine = .init(gpa, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.deinit();
    engine.execute_fn = failCover;
    var model: lib.Model = .{ .gpa = gpa };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root, .load_cover = thumbnail };
    session.browser.engine = &engine;
    defer session.deinit();
    session.setStatus("Ready");
    try std.testing.expect(session.coverImage(remote_manga) == null);
    session.cover_job.?.join();
    try session.poll();
    session.beginCoverFrame();
    try std.testing.expect(session.coverImage(remote_manga) == null);
    try std.testing.expect(session.cover_job == null);
    try std.testing.expect(session.browser.busy == null);
    try std.testing.expectEqualStrings("Ready", session.status);
    try std.testing.expectEqual(1, requests.load(.monotonic));
}

test "foreground requests cancel and join optional cover work before starting" {
    requests.store(0, .monotonic);
    canceled.store(false, .monotonic);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var engine: tachi.Engine = .init(gpa, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.deinit();
    engine.execute_fn = cancelCover;
    var model: lib.Model = .{ .gpa = gpa };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root, .load_cover = thumbnail };
    session.browser.engine = &engine;
    defer session.deinit();
    try std.testing.expect(session.coverImage(remote_manga) == null);
    while (requests.load(.acquire) == 0) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    session.start(.sources);
    try std.testing.expect(session.cover_job == null);
    try std.testing.expect(canceled.load(.acquire));
    try std.testing.expect(session.browser.busy != null);
    session.browser.busy.?.join();
    try session.poll();
}

var worker_ready: bool = false;
fn readyWorker(_: *Session) bool {
    return worker_ready;
}

test "optional artwork waits for a ready worker without suppressing a later fetch" {
    requests.store(0, .monotonic);
    worker_ready = false;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var engine: tachi.Engine = .init(gpa, std.testing.io, tachi.backend.none, .{ .dir = root });
    defer engine.deinit();
    engine.execute_fn = cacheCover;
    var model: lib.Model = .{ .gpa = gpa };
    var session: Session = .{ .model = &model, .io = std.testing.io, .root = root, .load_cover = thumbnail, .can_fetch_cover = readyWorker };
    session.browser.engine = &engine;
    defer session.deinit();
    session.setStatus("Ready");
    try std.testing.expect(session.coverImage(remote_manga) == null);
    try std.testing.expect(session.cover_job == null);
    try std.testing.expect(session.browser.busy == null);
    try std.testing.expectEqual(0, requests.load(.monotonic));
    try std.testing.expectEqualStrings("Ready", session.status);
    worker_ready = true;
    try std.testing.expect(session.coverImage(remote_manga) == null);
    try std.testing.expect(session.cover_job != null);
    session.cover_job.?.join();
    try session.poll();
    try std.testing.expect(session.coverImage(remote_manga) != null);
    try std.testing.expectEqual(1, requests.load(.monotonic));
}
