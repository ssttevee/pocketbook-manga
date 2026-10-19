//! Build/test diagnostic, never part of the reader's Applications folder.
const std = @import("std");
const online = @import("online.zig");
pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const root = it.next() orelse return error.MissingBundleRoot;
    const cmd = it.next() orelse "sources";
    var engine: online.Engine = .{ .gpa = init.gpa, .io = init.io, .root = root, .environ = init.minimal.environ };
    const request: online.Request = if (std.mem.eql(u8, cmd, "repo")) .extensions else if (std.mem.eql(u8, cmd, "install")) .{ .install = it.next() orelse return error.MissingPackage } else .sources;
    const job = try online.Job.start(&engine, request);
    defer job.deinit();
    job.join();
    if (job.failure) |failure| {
        std.debug.print("{s}\n", .{failure});
        return error.RuntimeProbeFailed;
    }
    std.debug.print("ARM JNI host: {d} installed sources, {d} repository extensions\n", .{ job.result.sources.len, job.result.extensions.len });
    if (std.mem.eql(u8, cmd, "fixture")) {
        const file = it.next() orelse return error.MissingFixture;
        const installed = try engine.runtime.?.installExtension(file);
        init.gpa.free(installed);
        const titles = try runJob(&engine, .{ .titles = .{ .source = 424242, .query = "fixture" } });
        defer titles.deinit();
        if (titles.result.titles.?.mangas.len != 1) return error.FixtureSearchFailed;
        const added = try runJob(&engine, .{ .add = .{ .source = 424242, .manga = titles.result.titles.?.mangas[0] } });
        defer added.deinit();
        const library_path = try std.fs.path.join(init.gpa, &.{ root, "library.json" });
        const library = try @import("library.zig").readJson(@import("library.zig").Library, init.gpa, init.io, library_path);
        defer library.deinit();
        const book = library.value.manga[0];
        const downloaded = try runJob(&engine, .{ .download = .{ .book = book, .chapter = book.chapters[0] } });
        defer downloaded.deinit();
        const ready = try @import("library.zig").readJson(@import("library.zig").Library, init.gpa, init.io, library_path);
        defer ready.deinit();
        if (ready.value.manga[0].chapters[0].pages.len != 1) return error.FixtureDownloadFailed;
        const page_path = try std.fs.path.join(init.gpa, &.{ root, ready.value.manga[0].chapters[0].pages[0] });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, page_path, init.gpa, .limited(1 << 20));
        defer init.gpa.free(bytes);
        if (!std.mem.startsWith(u8, bytes, "\x89PNG")) return error.FixtureNotPng;
        std.debug.print("ARM extension install, search, details, chapters and authenticated image download passed ({d} bytes).\n", .{bytes.len});
    }
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
