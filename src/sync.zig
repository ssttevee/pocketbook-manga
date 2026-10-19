const std = @import("std");
const Io = std.Io;
const tachi = @import("tachi");
const lib = @import("library.zig");
const local = @import("local.zig");
const usage =
    \\PocketManga companion
    \\  pocketmanga-sync [options] import
    \\  pocketmanga-sync [options] sources
    \\  pocketmanga-sync [options] repo
    \\  pocketmanga-sync [options] install PACKAGE
    \\  pocketmanga-sync [options] popular SOURCE_ID
    \\  pocketmanga-sync [options] search SOURCE_ID QUERY
    \\  pocketmanga-sync [options] chapters SOURCE_ID MANGA_URL
    \\  pocketmanga-sync [options] download SOURCE_ID MANGA_URL CHAPTER_URL
    \\
    \\Options: --root DIR (default ./library), --data-dir DIR (default ./.tachi-data),
    \\         --host-jar FILE, --java-home DIR
    \\Import scans ROOT/Title/Chapter/{001.jpg,002.png,...} and writes library.json.
    \\Downloads use the source's own HTTP client and only publish complete chapters.
    \\
;
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("PocketManga: {s}\n{s}\n", .{ @errorName(err), tachi.lastError() });
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = init.io;
    var it = init.minimal.args.iterate();
    _ = it.next();
    var root: []const u8 = "library";
    var data: []const u8 = ".tachi-data";
    var jar: ?[]const u8 = null;
    var java: ?[]const u8 = null;
    var args: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root")) root = it.next() orelse return error.MissingRoot else if (std.mem.eql(u8, arg, "--data-dir")) data = it.next() orelse return error.MissingDataDir else if (std.mem.eql(u8, arg, "--host-jar")) jar = it.next() orelse return error.MissingHostJar else if (std.mem.eql(u8, arg, "--java-home")) java = it.next() orelse return error.MissingJavaHome else try args.append(gpa, arg);
    }
    var out_buffer: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (args.items.len == 0 or std.mem.eql(u8, args.items[0], "--help")) {
        try out.writeAll(usage);
        return;
    }
    const cmd = args.items[0];
    if (std.mem.eql(u8, cmd, "import")) {
        try Io.Dir.cwd().createDirPath(io, root);
        const library = try local.scan(gpa, io, root);
        const path = try std.fs.path.join(gpa, &.{ root, "library.json" });
        // Preserve downloaded titles; importing only updates titles found on disk.
        const old = lib.readJson(lib.Library, gpa, io, path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        var merged = if (old) |p| p.value else lib.Library{};
        try lib.validate(merged);
        for (library.manga) |manga| merged = try merge(gpa, merged, manga);
        try lib.validate(merged);
        try lib.writeJson(gpa, io, path, merged);
        try out.print("Indexed {d} local titles into {s}\n", .{ library.manga.len, path });
        return;
    }
    // Check syntax before starting a JVM.
    const needed: usize = if (std.mem.eql(u8, cmd, "download")) 4 else if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "chapters")) 3 else if (std.mem.eql(u8, cmd, "popular") or std.mem.eql(u8, cmd, "install")) 2 else if (std.mem.eql(u8, cmd, "sources") or std.mem.eql(u8, cmd, "repo")) 1 else return error.UnknownCommand;
    if (args.items.len != needed) return error.InvalidArguments;
    const rt = try tachi.Runtime.init(init.gpa, io, .{ .data_dir = data, .host_jar = jar, .java_home = java, .environ = init.minimal.environ });
    defer rt.deinit();
    const restored = try rt.restore();
    defer init.gpa.free(restored);
    const restore_info = try std.json.parseFromSlice(tachi.manage.RestoreResult, gpa, restored, tachi.models.parse_options);
    for (restore_info.value.failed) |failure| std.debug.print("Source restore failed: {s}: {s}\n", .{ failure.pkg, failure.@"error" });
    if (std.mem.eql(u8, cmd, "sources") or std.mem.eql(u8, cmd, "repo") or std.mem.eql(u8, cmd, "install")) {
        const json = if (std.mem.eql(u8, cmd, "sources")) try rt.listExtensions() else if (std.mem.eql(u8, cmd, "repo")) try rt.repoListJson(.{}) else try rt.repoInstall(args.items[1], .{});
        defer init.gpa.free(json);
        try out.print("{s}\n", .{json});
        return;
    }
    const id = try std.fmt.parseInt(i64, args.items[1], 10);
    if (std.mem.eql(u8, cmd, "download")) {
        try download(gpa, init.gpa, io, rt, root, id, args.items[2], args.items[3], out);
        return;
    }
    const call_args = if (std.mem.eql(u8, cmd, "popular")) try std.json.Stringify.valueAlloc(gpa, .{ .page = 1 }, .{}) else if (std.mem.eql(u8, cmd, "search")) try std.json.Stringify.valueAlloc(gpa, .{ .page = 1, .query = args.items[2] }, .{}) else try std.json.Stringify.valueAlloc(gpa, .{ .manga = .{ .url = args.items[2], .title = "" } }, .{});
    const json = try rt.call(id, cmd, call_args);
    defer init.gpa.free(json);
    try out.print("{s}\n", .{json});
}
pub fn merge(gpa: std.mem.Allocator, old: lib.Library, manga: lib.Manga) !lib.Library {
    for (old.manga, 0..) |m, i| if (std.mem.eql(u8, m.id, manga.id)) {
        const titles = try gpa.dupe(lib.Manga, old.manga);
        var chapters: std.ArrayList(lib.Chapter) = .empty;
        try chapters.appendSlice(gpa, m.chapters);
        for (manga.chapters) |ch| {
            var found = false;
            for (chapters.items) |*existing| if (std.mem.eql(u8, existing.id, ch.id)) {
                existing.* = ch;
                found = true;
                break;
            };
            if (!found) try chapters.append(gpa, ch);
        }
        std.mem.sort(lib.Chapter, chapters.items, {}, struct {
            fn less(_: void, a: lib.Chapter, b: lib.Chapter) bool {
                return local.naturalLess({}, a.title, b.title);
            }
        }.less);
        titles[i] = manga;
        titles[i].chapters = chapters.items;
        return .{ .manga = titles };
    };
    const titles = try gpa.alloc(lib.Manga, old.manga.len + 1);
    @memcpy(titles[0..old.manga.len], old.manga);
    titles[old.manga.len] = manga;
    return .{ .manga = titles };
}
fn download(gpa: std.mem.Allocator, runtime_gpa: std.mem.Allocator, io: Io, rt: *tachi.Runtime, root: []const u8, id: i64, manga_url: []const u8, chapter_url: []const u8, out: *Io.Writer) !void {
    const path = try std.fs.path.join(gpa, &.{ root, "library.json" });
    const existing = lib.readJson(lib.Library, gpa, io, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const old = if (existing) |p| p.value else lib.Library{};
    try lib.validate(old);
    const margs = try std.json.Stringify.valueAlloc(gpa, .{ .manga = .{ .url = manga_url, .title = "" } }, .{});
    const details = try rt.callParsed(tachi.models.Manga, id, "details", margs);
    defer details.deinit();
    const chapters = try rt.callParsed([]const tachi.models.Chapter, id, "chapters", margs);
    defer chapters.deinit();
    var selected: ?tachi.models.Chapter = null;
    for (chapters.value()) |ch| if (std.mem.eql(u8, ch.url, chapter_url)) {
        selected = ch;
        break;
    };
    const ch = selected orelse return error.ChapterNotInSource;
    const pargs = try std.json.Stringify.valueAlloc(gpa, .{ .chapter = ch }, .{});
    const pages = try rt.callParsed([]const tachi.models.Page, id, "pages", pargs);
    defer pages.deinit();
    if (pages.value().len == 0) return error.EmptyChapter;
    const manga_id = try std.fmt.allocPrint(gpa, "{d}:{s}", .{ id, manga_url });
    const chapter_id = try std.fmt.allocPrint(gpa, "{d}:{s}", .{ id, chapter_url });
    const folder = try std.fmt.allocPrint(gpa, "downloads/{x}/{d}", .{ std.hash.Wyhash.hash(0, chapter_id), Io.Clock.real.now(io).nanoseconds });
    const absolute = try std.fs.path.join(gpa, &.{ root, folder });
    try Io.Dir.cwd().createDirPath(io, absolute);
    var files: std.ArrayList([]const u8) = .empty;
    for (pages.value(), 0..) |page, i| {
        const page_json = try std.json.Stringify.valueAlloc(gpa, page, .{});
        const image = try rt.fetchImage(id, page_json);
        defer image.deinit(runtime_gpa);
        // Fail explicitly for WebP/AVIF; libinkview cannot display those.
        const ext = if (image.bytes.len >= 8 and std.mem.startsWith(u8, image.bytes, "\x89PNG\r\n\x1a\n")) "png" else if (image.bytes.len >= 3 and std.mem.startsWith(u8, image.bytes, "\xff\xd8\xff")) "jpg" else return error.UnsupportedImageFormat;
        const relative = try std.fmt.allocPrint(gpa, "{s}/{d:0>4}.{s}", .{ folder, i + 1, ext });
        const destination = try std.fs.path.join(gpa, &.{ root, relative });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = image.bytes });
        try files.append(gpa, relative);
        try out.print("Downloaded {d}/{d}\n", .{ i + 1, pages.value().len });
        try out.flush();
    }
    const manga: lib.Manga = .{ .id = manga_id, .title = details.value().title, .author = details.value().author orelse "", .description = details.value().description orelse "", .chapters = &.{.{ .id = chapter_id, .title = ch.name, .pages = files.items }} };
    const merged = try merge(gpa, old, manga);
    try lib.validate(merged);
    try lib.writeJson(gpa, io, path, merged);
    try out.print("Ready: {s} / {s}\nCopy {s} to applications/pocketmanga on the reader.\n", .{ manga.title, ch.name, root });
}
