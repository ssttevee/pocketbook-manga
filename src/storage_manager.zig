//! A compact chapter inventory. Selections own IDs rather than borrowing a
//! library snapshot, so reloads and page changes cannot invalidate them.
const std = @import("std");
const f = @import("fabrum");
const app = f.app;
const Session = @import("session.zig").Session;
const tachi = @import("tachi");
const Self = @This();
pub const Pager = struct { handler: app.Handler(Page), size: usize };
pub const Props = struct { series: bool = false, on_pager: ?app.Handler(Pager) = null };
pub const Row = struct { id: []const u8, series: []const u8, chapter: []const u8, pages: usize, total: usize, chapter_ids: []const []const u8 = &.{} };
pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    rows: []const Row = &.{},
    selected: std.StringHashMapUnmanaged(void) = .empty,
    offset: usize = 0,
    loaded: bool = false,
    revision: u64 = 0,
    busy: bool = false,
    operation: Operation = .delete,
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.selected.deinit(gpa);
        if (self.arena) |*arena| arena.deinit();
    }
    pub fn clear(self: *State, gpa: std.mem.Allocator) void {
        var keys = self.selected.keyIterator();
        while (keys.next()) |id| gpa.free(id.*);
        self.selected.clearRetainingCapacity();
    }
    pub fn toggle(self: *State, gpa: std.mem.Allocator, id: []const u8) !void {
        if (self.selected.fetchRemove(id)) |removed| {
            gpa.free(removed.key);
        } else {
            const owned = try gpa.dupe(u8, id);
            errdefer gpa.free(owned);
            try self.selected.put(gpa, owned, {});
        }
    }
    fn acceptRows(self: *State, gpa: std.mem.Allocator, source: []const Row) !void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const rows = try a.dupe(Row, source);
        for (rows) |*row| {
            row.id = try a.dupe(u8, row.id);
            row.series = try a.dupe(u8, row.series);
            row.chapter = try a.dupe(u8, row.chapter);
            const ids = try a.dupe([]const u8, row.chapter_ids);
            for (ids) |*id| id.* = try a.dupe(u8, id.*);
            row.chapter_ids = ids;
        }
        if (self.arena) |*old| old.deinit();
        self.arena = arena;
        self.rows = rows;
        self.offset = @min(self.offset, self.rows.len -| 1);
        self.loaded = true;
    }
};
pub const Operation = enum { delete, read, unread, move_internal, move_sd };
pub const Page = struct { delta: i32, size: usize };
pub const Msg = union(enum) { loaded: anyerror![]const Row, toggle: []const u8, all, clear, page: Page, operation: Operation, answer: ?usize, completed: anyerror!usize };

fn inspect(task: *app.Task, engine: *tachi.Engine, series: bool) anyerror![]const Row {
    const library = try engine.loadLibrary(task.gpa);
    var rows: std.ArrayList(Row) = .empty;
    for (library.manga) |manga| {
        if (manga.local()) continue;
        const first = rows.items.len;
        for (manga.chapters) |chapter| {
            try task.checkCancel();
            var done = chapter.pages.len;
            var total = done;
            if (done == 0) {
                const partial = try engine.downloadProgress(task.gpa, chapter.id) orelse continue;
                done = partial.done;
                total = partial.total;
            }
            try rows.append(task.gpa, .{ .id = chapter.id, .series = manga.title, .chapter = chapter.title, .pages = done, .total = total });
        }
        if (series and rows.items.len > first) {
            const chapters = rows.items[first..];
            const ids = try task.gpa.alloc([]const u8, chapters.len);
            var pages: usize = 0;
            var total: usize = 0;
            for (chapters, ids) |row, *id| {
                id.* = row.id;
                pages += row.pages;
                total += row.total;
            }
            rows.shrinkRetainingCapacity(first);
            try rows.append(task.gpa, .{ .id = manga.id, .series = manga.title, .chapter = try std.fmt.allocPrint(task.gpa, "{d} downloaded chapters", .{ids.len}), .pages = pages, .total = total, .chapter_ids = ids });
        }
    }
    return rows.toOwnedSlice(task.gpa);
}

fn operate(task: *app.Task, engine: *tachi.Engine, ids: []const []const u8, operation: Operation) anyerror!usize {
    try task.checkCancel();
    if (engine.queue.running()) return error.DownloadQueueRunning;
    return switch (operation) {
        .delete => engine.deleteDownloads(ids),
        .read, .unread => engine.markRead(ids, operation == .read),
        .move_internal, .move_sd => @import("storage_move.zig").move(engine, ids, operation == .move_sd, .{ .context = task, .check = checkMoveCancel }),
    };
}

fn checkMoveCancel(context: *anyopaque) anyerror!void {
    const task: *app.Task = @ptrCast(@alignCast(context));
    try task.checkCancel();
}

fn beginOperation(state: *State, session: *Session, ctx: *app.Update(Self), operation: Operation) !void {
    var targets: std.ArrayList([]const u8) = .empty;
    for (state.rows) |row| if (state.selected.contains(row.id)) {
        if (row.chapter_ids.len > 0) try targets.appendSlice(ctx.core.arena.allocator(), row.chapter_ids) else try targets.append(ctx.core.arena.allocator(), row.id);
    };
    const ids = targets.items;
    state.busy = true;
    session.storage_busy = true;
    state.operation = operation;
    errdefer {
        state.busy = false;
        session.storage_busy = false;
    }
    try ctx.run(operate, .{ session.browser.engine.?, ids, operation }, ctx.handler(.completed));
}

pub fn update(state: *State, msg: Msg, ctx: *app.Update(Self)) !void {
    const session = @constCast(ctx.use(Session));
    const engine = session.browser.engine orelse return;
    switch (msg) {
        .loaded => |outcome| {
            const rows = outcome catch |err| {
                if (err != error.Canceled) try session.formatStatus("Cannot list downloads: {s}", .{@errorName(err)});
                return;
            };
            try state.acceptRows(ctx.gpa, rows);
        },
        .toggle => |id| if (!state.busy) try state.toggle(ctx.gpa, id),
        .all => if (!state.busy) {
            for (state.rows) |row| if (!state.selected.contains(row.id)) try state.toggle(ctx.gpa, row.id);
        },
        .clear => if (!state.busy) state.clear(ctx.gpa),
        .page => |page| {
            if (page.delta < 0) state.offset -|= page.size else if (state.offset + page.size < state.rows.len) state.offset += page.size;
        },
        .operation => |operation| {
            if (state.busy or session.browser.busy != null or session.read_download != null or engine.queue.running() or state.selected.count() == 0) return;
            if (operation == .delete) {
                try ctx.confirm(.{ .title = "Delete downloads", .text = "Delete the selected chapters' downloaded files? Library entries and reading progress are kept. Protected chapters follow your deletion settings.", .buttons = &.{ "Delete", "Keep" }, .default = 1 }, ctx.handler(.answer));
            } else try beginOperation(state, session, ctx, operation);
        },
        .answer => |answer| if (answer == 0 and !state.busy and session.browser.busy == null and session.read_download == null and !engine.queue.running()) {
            try beginOperation(state, session, ctx, .delete);
        },
        .completed => |outcome| {
            state.busy = false;
            session.storage_busy = false;
            const count = outcome catch |err| {
                if (state.operation == .move_internal or state.operation == .move_sd) {
                    try session.reloadLibrary();
                    state.loaded = false;
                    state.revision +%= 1;
                }
                if (err == error.StorageUnavailable) {
                    if (state.operation == .delete) session.setStatus("Insert the SD card holding these downloads before deleting them.") else session.setStatus("Insert the SD card before moving these downloads.");
                } else if (err == error.DestinationHasDownloads) session.setStatus("The destination already has files for a selected chapter. The original downloads were kept.") else if (err == error.NoSpaceLeft) session.setStatus("There is not enough free space on the destination disk.") else try session.formatStatus("Cannot update selected chapters: {s}", .{@errorName(err)});
                return;
            };
            try session.reloadLibrary();
            switch (state.operation) {
                .delete => {
                    state.clear(ctx.gpa);
                    state.loaded = false;
                    state.revision +%= 1;
                    try session.formatStatus("Deleted {d} chapter downloads. Protected chapters were kept.", .{count});
                    session.status_transient = true;
                },
                .read => session.notify("Selected chapters marked read"),
                .unread => session.notify("Selected chapters marked unread"),
                .move_internal, .move_sd => {
                    state.clear(ctx.gpa);
                    state.loaded = false;
                    state.revision +%= 1;
                    try session.formatStatus("Moved {d} chapter downloads to {s}.", .{ count, if (state.operation == .move_sd) "SD card" else "internal storage" });
                    session.status_transient = true;
                },
            }
        },
    }
}

pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
    const session = ui.use(Session);
    const on = ui.messages(Self);
    if (session.browser.engine) |engine| try ui.task("download-inventory", .{ .restart = state.revision }, inspect, .{ engine, props.series }, on.handler(.loaded));
    try ui.open("download-manager", .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(8), .child_gap = 6 } });
    defer ui.close();
    try ui.print(.{ .font_size = 13 }, "{d} {s} · {d} selected", .{ state.rows.len, if (props.series) "series" else if (state.rows.len == 1) "chapter" else "chapters", state.selected.count() });
    {
        try ui.open("selection-actions", .{ .layout = .{ .child_gap = 6 } });
        defer ui.close();
        try app.widgets.button(ui, "select-all", .{ .label = "Select all", .enabled = state.loaded and !state.busy and state.rows.len > 0, .on_click = on.bind(.all) });
        try app.widgets.button(ui, "clear-selection", .{ .label = "Clear selection", .enabled = !state.busy and state.selected.count() > 0, .on_click = on.bind(.clear) });
    }
    const size: usize = @max(1, @as(usize, @intFromFloat(@max(0, ui.core.viewport.y - (if (session.model.prefs.hide_navigation) @as(f32, 208) else 246)))) / 50);
    if (props.on_pager) |handler| try ui.after(.{ "register-pager", size }, .fromMilliseconds(0), try handler.withAlloc(ui.arena(), .{ .handler = on.handler(.page), .size = size }));
    const start = if (state.loaded) @min(state.offset, state.rows.len) else 0;
    const end = if (state.loaded) @min(start + size, state.rows.len) else 0;
    if (!state.loaded) try ui.text(if (props.series) "Loading downloaded series..." else "Loading downloaded chapters...", .{ .font_size = 15 }) else if (state.rows.len == 0) try ui.text("No downloaded chapters", .{ .font_size = 15 });
    for (state.rows[start..end]) |row| {
        try ui.open(row.id, .{
            .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(44) }, .axis = .y, .padding = .all(4) },
            .background_color = if (state.selected.contains(row.id)) .gray(220) else .white,
            .border = .{ .color = .gray(180), .widths = .{ .bottom = 1 } },
            .clip = .{ .horizontal = true, .vertical = true },
            .on_click = if (state.busy) null else on.bind(.{ .toggle = row.id }),
        });
        try ui.print(.{ .font_size = 13, .wrap_mode = .none }, "{s} {s}", .{ if (state.selected.contains(row.id)) "[x]" else "[ ]", row.series });
        try ui.print(.{ .font_size = 12, .wrap_mode = .none }, "{s} · {d}/{d}", .{ row.chapter, row.pages, row.total });
        ui.close();
    }
    ui.spacer();
    {
        try ui.open("bulk-actions", .{ .layout = .{ .child_gap = 4 } });
        defer ui.close();
        const enabled = !state.busy and session.browser.busy == null and session.read_download == null and state.selected.count() > 0 and !(if (session.browser.engine) |engine| engine.queue.running() else false);
        inline for (.{ .{ "Delete", Operation.delete }, .{ "Read", Operation.read }, .{ "Unread", Operation.unread } }) |action| try app.widgets.button(ui, action[0], .{ .label = if (props.series and action[1] == .delete) "Delete downloads" else action[0], .enabled = enabled, .on_click = on.bind(.{ .operation = action[1] }) });
    }
    {
        try ui.open("move-actions", .{ .layout = .{ .child_gap = 4 } });
        defer ui.close();
        const enabled = !state.busy and session.browser.busy == null and session.read_download == null and state.selected.count() > 0 and !(if (session.browser.engine) |engine| engine.queue.running() else false);
        try app.widgets.button(ui, "move-internal", .{ .label = "Move to internal", .enabled = enabled, .on_click = on.bind(.{ .operation = .move_internal }) });
        try app.widgets.button(ui, "move-sd", .{ .label = "Move to SD", .enabled = enabled and (if (session.browser.engine) |engine| engine.sdAvailable() else false), .on_click = on.bind(.{ .operation = .move_sd }) });
    }
    if (state.busy) try ui.text(if (state.operation == .delete) "Deleting downloads..." else if (state.operation == .move_internal or state.operation == .move_sd) "Moving downloads..." else "Updating reading progress...", .{ .font_size = 13 });
    if (!session.model.prefs.hide_navigation) {
        try ui.open("manager-pages", .{ .layout = .{ .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try app.widgets.button(ui, "previous", .{ .label = "Previous", .enabled = start > 0, .on_click = on.bind(.{ .page = Page{ .delta = -1, .size = size } }) });
        try ui.print(.{ .font_size = 12 }, "{d}-{d}/{d}", .{ if (state.rows.len == 0) @as(usize, 0) else start + 1, end, state.rows.len });
        try app.widgets.button(ui, "next", .{ .label = "Next", .enabled = state.loaded and end < state.rows.len, .on_click = on.bind(.{ .page = Page{ .delta = 1, .size = size } }) });
    }
}
