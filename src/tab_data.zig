//! Root-tab database views are built away from the input and paint thread.
//! Results use stable IDs, so an unrelated library reload cannot invalidate them.
const std = @import("std");
const app = @import("fabrum").app;
const tachi = @import("tachi");
const lib = @import("library.zig");
const Session = @import("session.zig").Session;

pub const Result = struct {
    request: Session.TabRequest,
    category: usize,
    category_id: u32,
    categories: []const []const u8,
    titles: []const []const u8,
    feed: []const Row,
    pub const Row = struct { chapter: []const u8, title: []const u8, detail: []const u8 };
};

pub const Outcome = struct { request: Session.TabRequest, value: anyerror!Result };

pub fn load(task: *app.Task, engine: *tachi.Engine, request: Session.TabRequest) Outcome {
    return .{ .request = request, .value = loadData(task, engine, request) };
}

fn loadData(task: *app.Task, engine: *tachi.Engine, request: Session.TabRequest) anyerror!Result {
    try task.checkCancel();
    var model: lib.Model = .{
        .gpa = task.gpa,
        .library = try engine.loadLibrary(task.gpa),
        .screen = request.screen,
        .category = request.category,
        .query_text = request.query,
    };
    var session: Session = .{ .model = &model, .io = task.io, .root = engine.options.dir };
    session.browser.engine = engine;
    // These arenas borrow the task allocator; their contents live through result
    // delivery, and are reclaimed even if a canceled task's result is discarded.
    if (request.screen == .library) try session.refreshRows() else try session.refreshFeed();
    try task.checkCancel();
    const titles = try task.gpa.alloc([]const u8, model.titleCount());
    for (titles, 0..) |*id, index| id.* = model.library.manga[model.titleIndex(index)].id;
    const feed = try task.gpa.alloc(Result.Row, session.feed.len);
    for (session.feed, feed) |row, *dest| dest.* = .{
        .chapter = model.library.manga[row.pick.manga].chapters[row.pick.chapter].id,
        .title = row.title,
        .detail = row.detail,
    };
    return .{ .request = request, .category = model.category, .category_id = session.category_id, .categories = model.categories, .titles = titles, .feed = feed };
}

pub fn current(session: *const Session, request: Session.TabRequest) bool {
    const pending = session.tab_request orelse return false;
    return pending.generation == request.generation and pending.screen == session.model.screen and
        pending.category == session.model.category and std.mem.eql(u8, pending.query, session.model.query_text);
}

pub fn accept(session: *Session, result: Result) !void {
    if (!current(session, result.request)) return;
    const model = session.model;
    var arena: std.heap.ArenaAllocator = .init(model.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    if (model.screen == .library) {
        var indices: std.StringHashMapUnmanaged(usize) = .empty;
        for (model.library.manga, 0..) |manga, index| try indices.put(a, manga.id, index);
        var titles: std.ArrayList(usize) = .empty;
        for (result.titles) |id| if (indices.get(id)) |index| try titles.append(a, index);
        const names = try a.alloc([]const u8, result.categories.len);
        for (result.categories, names) |name, *dest| dest.* = try a.dupe(u8, name);
        model.title_rows = titles.items;
        model.chapter_rows = null;
        model.categories = names;
        model.category = result.category;
        session.category_id = result.category_id;
        session.chapter_downloads = &.{};
        if (session.rows_arena) |*old| old.deinit();
        session.rows_arena = arena;
    } else {
        var picks: std.StringHashMapUnmanaged(lib.Pick) = .empty;
        for (model.library.manga, 0..) |manga, mi| for (manga.chapters, 0..) |chapter, ci| try picks.put(a, chapter.id, .{ .manga = mi, .chapter = ci });
        var feed: std.ArrayList(@import("session.zig").FeedRow) = .empty;
        for (result.feed) |row| if (picks.get(row.chapter)) |pick| try feed.append(a, .{
            .pick = pick,
            .title = try a.dupe(u8, row.title),
            .detail = try a.dupe(u8, row.detail),
        });
        session.feed = feed.items;
        model.feed_count = feed.items.len;
        if (session.feed_arena) |*old| old.deinit();
        session.feed_arena = arena;
    }
    model.offset = 0;
    session.tab_request = null;
}
