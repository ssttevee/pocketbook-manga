const std = @import("std");
const f = @import("fabrum");
const app = f.app;
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @This();
const tachi = @import("tachi");
const models = tachi.models;
const storage = @import("storage.zig");
const regions = @import("region_service.zig");
pub const OnlineCommand = union(enum) { stores, refresh_stores, remove_store: usize, toggle_pin, toggle_hidden, show_hidden, languages, toggle_language: usize, sources, extensions, reload_sources, pick_source: usize, pick_title: usize, extension: usize, next, previous, search, latest, source_settings, preference: usize, uninstall, refresh_book, update_all, scan, cancel, queue_unread, queue_start, queue_pause, queue_clear, find_alternative: usize, pick_global: usize };
pub const BackupCommand = enum { create, export_downloads, import_downloads };
pub const Navigation = enum { library, updates, history, browse, more };
pub const State = struct { storage_snapshot: ?storage.Snapshot = null, storage_revision: u32 = 0, storage_clearing: bool = false, more_root: bool = false, reading_from_more: bool = false, focused: bool = false, tapping: bool = false, pointer_start: ?f.Vec2 = null, reader_updates: u8 = 0 };
pub const Props = struct {};
pub const Msg = union(enum) { storage_loaded: anyerror!storage.Snapshot, storage_cleared: anyerror!void, storage_action: enum { internal, sd_card, clear_cache, manage }, jump_chapter, chapter_target: ?[]const u8, region_frame: anyerror!regions.Result, navigate: Navigation, reading_settings, library_grid, act: lib.Action, track: Session.TrackEdit, login_user: []const u8, login_password: []const u8, add_store: []const u8, confirm_add: bool, global_query: []const u8, edit: Session.Edit, setting: lib.Setting, category_edit: Session.CategoryEdit, new_category: []const u8, restore: usize, backup_command: BackupCommand, key: app.KeyEvent, pointer: app.Pointer, query: []const u8, online_query: []const u8, online: OnlineCommand, poll, pref_text: ?[]const u8, pref_choice: ?usize, remove_answer: ?usize, focus, quit };

pub fn update(state: *State, msg: Msg, ctx: *app.Update(Root)) !void {
    const session = @constCast(ctx.use(Session));
    switch (msg) {
        .jump_chapter => try ctx.systemText(.{ .title = "Jump to chapter number or exact title", .initial = "" }, ctx.handler(.chapter_target)),
        .chapter_target => |target| if (target) |value| {
            session.act(.{ .jump_chapter = value }) catch |err| {
                if (err == error.ChapterNotFound) session.setStatus("Chapter not found in this list") else return err;
            };
        },
        .storage_loaded => |outcome| {
            state.storage_snapshot = outcome catch |err| {
                if (err != error.Canceled) try session.formatStatus("Cannot inspect storage: {s}", .{@errorName(err)});
                return;
            };
        },
        .storage_cleared => |outcome| {
            state.storage_clearing = false;
            outcome catch |err| {
                if (err != error.Canceled) try session.formatStatus("Cannot clear cache: {s}", .{@errorName(err)});
                return;
            };
            state.storage_revision +%= 1;
            session.setStatus("Online reading cache cleared. Downloaded chapters are kept.");
        },
        .storage_action => |action| {
            if (session.browser.busy != null or state.storage_clearing) return;
            switch (action) {
                .internal, .sd_card => session.setDownloadStorage(action == .sd_card) catch |err| {
                    try session.formatStatus("Download destination unchanged: {s}", .{@errorName(err)});
                },
                .clear_cache => if (session.browser.engine) |engine| {
                    if (engine.queue.running()) return;
                    state.storage_clearing = true;
                },
                .manage => if (session.browser.engine != null) {
                    session.storage_managing = true;
                    try session.act(.{ .feed = .library });
                    try session.refreshRows();
                    session.setStatus("Downloaded titles. Open a title, then use a chapter's menu to delete its download.");
                },
            }
        },
        .region_frame => |outcome| {
            const result = outcome catch |err| {
                if (err != error.Canceled) try session.formatStatus("Cannot render page: {s}", .{@errorName(err)});
                return;
            };
            if (try session.acceptRegion(result)) refreshReader(state, session, ctx);
        },
        .navigate => |destination| {
            if (session.browser.busy != null) return;
            const was_managing = session.storage_managing;
            session.storage_managing = false;
            if (was_managing) try session.refreshRows();
            // Reselecting Browse preserves its active tab, filter and list page.
            if (destination == .browse and (session.model.screen == .sources or session.model.screen == .extensions)) {
                ctx.focus("screen");
                return;
            }
            state.more_root = destination == .more;
            state.reading_from_more = false;
            session.browser.offset = 0;
            const action: lib.Action = switch (destination) {
                .library => .{ .feed = .library },
                .updates => .{ .feed = .updates },
                .history => .{ .feed = .history },
                .browse => .help,
                .more => .settings,
            };
            try session.act(action);
            if (destination == .browse) session.start(.sources);
            ctx.focus("screen");
        },
        .poll => {
            try session.poll();
            if (session.browser.busy == null) ctx.focus("screen");
        },
        .library_grid => try session.act(.library_grid),
        .reading_settings => {
            state.more_root = false;
            state.reading_from_more = true;
            ctx.focus("screen");
        },
        .online => |command| try onlineUpdate(session, command, ctx),
        .confirm_add => |add| if (session.browser.busy == null) session.confirmAdd(add),
        .track => |edit| if (session.browser.busy == null) {
            session.track(edit) catch |err| {
                try session.formatStatus("Tracking: {s}", .{@errorName(err)});
            };
        },
        .login_user => |name| try session.setLoginUsername(name),
        .login_password => |password| if (session.browser.busy == null and password.len > 0) {
            session.start(.{ .tracker = .{ .id = session.tracker_id, .operation = .{ .login = .{ .username = session.login_username, .password = password } } } });
        },
        .add_store => |url| if (session.browser.busy == null and std.mem.trim(u8, url, " ").len > 0) {
            session.start(.{ .add_store = std.mem.trim(u8, url, " ") });
        },
        .global_query => |query| if (session.browser.busy == null and std.mem.trim(u8, query, " ").len > 0) {
            if (session.browser.migrate_from) |id| session.model.gpa.free(id);
            session.browser.migrate_from = null;
            try session.globalSearch(query);
        },
        .category_edit => |change| if (session.browser.busy == null) {
            session.editCategory(change) catch |err| {
                try session.formatStatus("Category not changed: {s}", .{@errorName(err)});
            };
        },
        .new_category => |name| if (session.browser.busy == null) {
            session.addCategory(name) catch |err| {
                try session.formatStatus("Category not added: {s}", .{@errorName(err)});
            };
            ctx.focus("screen");
        },
        .restore => |row| if (session.browser.busy == null and row < session.feed.len) {
            // Jobs copy their request, so the path can go after starting.
            var arena: std.heap.ArenaAllocator = .init(session.model.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            session.start(.{ .import_backup = try std.fs.path.join(a, &.{ try session.backupDir(a), session.feed[row].title }) });
        },
        .backup_command => |command| if (session.browser.busy == null) {
            var arena: std.heap.ArenaAllocator = .init(session.model.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            switch (command) {
                .create => {
                    const dir = try session.backupDir(a);
                    try std.Io.Dir.cwd().createDirPath(session.io, dir);
                    session.start(.{ .export_backup = .{ .path = try std.fs.path.join(a, &.{ dir, try session.backupName(a) }) } });
                },
                .export_downloads => session.start(.{ .export_downloads = try session.mihonDownloadsDir(a) }),
                .import_downloads => session.start(.{ .import_downloads = try session.mihonDownloadsDir(a) }),
            }
        },
        .setting => |which| if (session.browser.busy == null) {
            session.changeSetting(which) catch |err| {
                try session.formatStatus("Setting not saved: {s}", .{@errorName(err)});
            };
            ctx.focus("screen");
        },
        .edit => |choice| if (session.browser.busy == null) {
            session.edit(choice) catch |err| {
                try session.formatStatus("Not changed: {s}", .{@errorName(err)});
            };
            ctx.focus("screen");
        },
        .online_query => |query| try session.browser.setQuery(session.model.gpa, query),
        .pref_text => |value| if (value) |v| try setPreference(session, .{ .string = v }),
        .pref_choice => |value| if (value) |i| {
            const pref = selectedPreference(session) orelse return;
            const values = pref.entryValues orelse return;
            if (i < values.len) {
                if (std.mem.eql(u8, pref.type, "multiselect")) {
                    var selected: std.array_list.Managed(std.json.Value) = .init(session.model.gpa);
                    defer selected.deinit();
                    const current = pref.value orelse pref.defaultValue orelse .null;
                    var exists = false;
                    if (current == .array) for (current.array.items) |item| {
                        if (item == .string and std.mem.eql(u8, item.string, values[i])) exists = true else try selected.append(item);
                    };
                    if (!exists) try selected.append(.{ .string = values[i] });
                    try setPreference(session, .{ .array = selected });
                } else try setPreference(session, .{ .string = values[i] });
            }
        },
        .remove_answer => |answer| if (answer == 0) {
            session.model.screen = .sources;
            session.browser.offset = 0;
            session.start(.{ .uninstall = session.browser.extension_pkg });
        },
        .focus => {
            state.focused = true;
            ctx.focus("screen");
        },
        .quit => try ctx.quit(),
        .query => |query| {
            try session.act(.{ .search = query });
            ctx.focus("screen");
        },
        .act => |action| {
            if (session.browser.busy != null) return;
            if (action == .back and session.storage_managing and session.model.screen == .library) {
                session.storage_managing = false;
                try session.act(.{ .feed = .storage });
                try session.refreshRows();
                return;
            }
            if (action == .back and state.reading_from_more and session.model.screen == .settings) {
                state.reading_from_more = false;
                state.more_root = true;
                ctx.focus("screen");
                return;
            }
            if (action == .settings) {
                state.more_root = false;
                state.reading_from_more = false;
            }
            if (action == .help) {
                session.browser.offset = 0;
                try session.act(action);
                session.start(.sources);
                return;
            }
            const effective: lib.Action = if (action == .back and state.more_root and (session.model.screen == .queue or session.model.screen == .upcoming or session.model.screen == .storage)) .{ .feed = .settings } else if (action == .next_chapter) .{ .read = session.next_chapter orelse return } else action;
            const pick: ?lib.Pick = switch (effective) {
                .read => |i| .{ .manga = session.model.manga, .chapter = i },
                .open_chapter => |p| p,
                else => null,
            };
            // A chapter not downloaded yet is downloaded first, then opened.
            if (pick) |p| if (p.manga < session.model.library.manga.len) {
                const book = session.model.library.manga[p.manga];
                if (p.chapter < book.chapters.len) {
                    const chapter = book.chapters[p.chapter];
                    if (chapter.pages.len == 0 and chapter.remote != null) {
                        session.model.manga = p.manga;
                        try session.browser.setPendingChapter(session.model.gpa, chapter.id);
                        session.start(.{ .download = chapter.id });
                        return;
                    }
                }
            };
            if (effective == .back) session.browser.offset = 0;
            try session.act(effective);
            if (session.model.screen == .reader) refreshReader(state, session, ctx);
            ctx.focus("screen");
        },
        .pointer => |event| {
            switch (event.phase) {
                .press => {
                    state.tapping = true;
                    state.pointer_start = event.local;
                },
                .drag => state.tapping = false,
                .cancel, .long_press => {
                    state.tapping = false;
                    state.pointer_start = null;
                },
                .release => {
                    const start = state.pointer_start orelse return;
                    state.pointer_start = null;
                    const was_tapping = state.tapping;
                    state.tapping = false;
                    const drag = event.local.sub(start);
                    if (@abs(drag.x) >= 12 or @abs(drag.y) >= 12) {
                        const geometry = session.model.reader_geometry orelse return;
                        const delta = readerDrag(geometry, drag, event.size);
                        if (delta == 0) return;
                        try session.act(.{ .pan = delta });
                    } else {
                        if (!was_tapping) return;
                        if (event.local.x < 0 or event.local.y < 0 or event.local.x > event.size.x or event.local.y > event.size.y) return;
                        // Edge zones reveal controls without advancing the page.
                        if (event.local.y < 48 or event.local.y >= event.size.y - 36) {
                            session.model.reader_controls = !session.model.reader_controls;
                            ctx.refresh(.page);
                            ctx.focus("screen");
                            return;
                        }
                        if (session.model.reader_controls) {
                            session.model.reader_controls = false;
                            ctx.refresh(.page);
                            return;
                        }
                        const left = event.local.x < event.size.x / 2;
                        const forward = left == session.model.prefs.rtl;
                        try session.act(.{ .turn = if (forward) 1 else -1 });
                    }
                    refreshReader(state, session, ctx);
                    ctx.focus("screen");
                },
            }
        },
        .key => |event| {
            if (event.phase != .press and event.phase != .repeat) return;
            const model = session.model;
            if (session.browser.busy != null) {
                if (event.key == .escape) {
                    session.browser.busy.?.cancel();
                    session.updateActivity();
                }
                return;
            }
            if (model.screen == .sources or model.screen == .extensions or model.screen == .catalog or model.screen == .source_settings) {
                if (event.key == .page_down or event.key == .right) {
                    try onlineUpdate(session, .next, ctx);
                    return;
                }
                if (event.key == .page_up or event.key == .left) {
                    try onlineUpdate(session, .previous, ctx);
                    return;
                }
            }
            const action: lib.Action = switch (event.key) {
                .escape => if (model.screen == .library and session.storage_managing) {
                    session.storage_managing = false;
                    try session.act(.{ .feed = .storage });
                    try session.refreshRows();
                    return;
                } else if (model.screen == .library) {
                    try ctx.quit();
                    return;
                } else .back,
                .page_down, .right => if (model.screen == .reader) .{ .turn = 1 } else .{ .list_page = 1 },
                .page_up, .left => if (model.screen == .reader) .{ .turn = -1 } else .{ .list_page = -1 },
                .f => |n| if (n == 10) .settings else return,
                else => return,
            };
            if (action == .settings) {
                state.more_root = false;
                state.reading_from_more = false;
            }
            if (action == .back and state.reading_from_more and model.screen == .settings) {
                state.reading_from_more = false;
                state.more_root = true;
                return;
            }
            const effective: lib.Action = if (action == .back and state.more_root and (model.screen == .queue or model.screen == .upcoming or model.screen == .storage)) .{ .feed = .settings } else action;
            try session.act(effective);
            if (model.screen == .reader) refreshReader(state, session, ctx);
        },
    }
}
// Panel policy leaves cleaning refreshes to reading, never to row press/release.
fn refreshReader(state: *State, session: *const Session, ctx: *app.Update(Root)) void {
    if (session.region_service != null and !session.regionCurrent()) return;
    state.reader_updates += 1;
    if (session.model.prefs.full_refresh or state.reader_updates >= 12) {
        state.reader_updates = 0;
        ctx.refresh(.page);
    }
}
fn rowFill(ui: *app.Ui, key: anytype) f.Color {
    // Same interaction queries and 12% pressed shading as app.drawn.button.
    if (ui.pressed(key)) return .gray(216);
    if (ui.capabilities().hover and ui.hovered(key)) return .gray(247);
    return .white;
}
fn downloadIdentity(ui: *app.Ui, series: []const u8, chapter: []const u8) !void {
    const style: f.layout.text.Style = .{ .font_size = 17, .wrap_mode = .words };
    const width = @max(1, ui.core.viewport.x - 24);
    const lines = try ui.core.make_lines(ui.core, series, style, width);
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y } });
        defer ui.close();
        if (lines.len > 2) {
            try text(ui, series[0..lines[0].end], 17, 0);
            try text(ui, try ui.fmt("{s}…", .{series[lines[1].start..]}), 17, 0);
        } else try ui.text(series, style);
    }
    try text(ui, chapter, 14, 0);
}
fn text(ui: *app.Ui, value: []const u8, size: f32, gray: u8) !void {
    const line = if (std.mem.indexOfAny(u8, value, "\r\n") != null) blk: {
        const copy = try ui.arena().dupe(u8, value);
        for (copy) |*byte| if (byte.* == '\r' or byte.* == '\n') {
            byte.* = ' ';
        };
        break :blk copy;
    } else value;
    try ui.text(line, .{ .font_size = size, .color = .gray(gray), .overflow = .ellipsis_end, .wrap_mode = .none });
}
fn button(ui: *app.Ui, key: anytype, label: []const u8, action: lib.Action) !void {
    try app.widgets.button(ui, key, .{ .label = label, .on_click = ui.messages(Root).bind(.{ .act = action }) });
}
fn rootNavigation(screen: lib.Screen, more_root: bool) ?Navigation {
    return switch (screen) {
        .library => .library,
        .updates => .updates,
        .history => .history,
        .sources, .extensions => .browse,
        .settings => if (more_root) .more else null,
        else => null,
    };
}

fn navigationBar(ui: *app.Ui, selected: Navigation, enabled: bool) !void {
    try ui.open("bottom-navigation", .{
        .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(58) }, .padding = .init(4, 4, 4, 4), .child_alignment = .center },
        .background_color = .gray(247),
        .border = .{ .color = .gray(220), .widths = .{ .top = 1 } },
    });
    defer ui.close();
    inline for (std.meta.tags(Navigation)) |destination| {
        const active = destination == selected;
        try ui.open(@tagName(destination), .{
            .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .grow(.{}) }, .axis = .y, .child_gap = 3, .child_alignment = .center },
            .on_click = if (enabled) ui.messages(Root).bind(.{ .navigate = destination }) else null,
            .focusable = enabled,
        });
        try ui.open(null, .{
            .layout = .{ .sizing = .{ .width = .fixed(44), .height = .fixed(25) }, .child_alignment = .center },
            .background_color = if (active or ui.pressed(@tagName(destination))) .gray(218) else .transparent,
            .corner_radius = .uniform(13),
        });
        try navigationIcon(ui, destination);
        ui.close();
        try text(ui, switch (destination) {
            .library => "Library",
            .updates => "Updates",
            .history => "History",
            .browse => "Browse",
            .more => "More",
        }, 11, if (active) 0 else 65);
        ui.close();
    }
}

// Draw the navigation marks from simple shapes so the device font needs no icons.
fn navigationIcon(ui: *app.Ui, destination: Navigation) !void {
    switch (destination) {
        .library => {
            try ui.open(null, .{ .layout = .{ .child_gap = 2, .child_alignment = .bottom_center } });
            for ([_]f32{ 13, 16, 12 }) |height| {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(4), .height = .fixed(height) } }, .border = .{ .color = .black, .widths = .outside(1) } });
                ui.close();
            }
            ui.close();
        },
        .updates => {
            try ui.open(null, .{ .layout = .{ .axis = .y, .child_gap = 3 } });
            for (0..3) |_| {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(16), .height = .fixed(2) } }, .background_color = .black });
                ui.close();
            }
            ui.close();
        },
        .history, .browse => {
            try ui.open(null, .{ .layout = .{ .sizing = .fixed(17) }, .border = .{ .color = .black, .widths = .outside(1) }, .corner_radius = .uniform(9) });
            if (destination == .history) {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(2), .height = .fixed(6) } }, .floating = .{ .mode = .parent, .offset = .init(7, 3) }, .background_color = .black });
                ui.close();
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(5), .height = .fixed(2) } }, .floating = .{ .mode = .parent, .offset = .init(7, 7) }, .background_color = .black });
                ui.close();
            } else {
                // A stepped diagonal needle stays crisp on the monochrome panel.
                for (0..7) |step| {
                    const position: f32 = @floatFromInt(step);
                    try ui.open(null, .{ .layout = .{ .sizing = .fixed(2) }, .floating = .{ .mode = .parent, .offset = .init(4 + position, 10 - position) }, .background_color = if (step < 3) .gray(125) else .black });
                    ui.close();
                }
            }
            ui.close();
        },
        .more => {
            try ui.open(null, .{ .layout = .{ .child_gap = 3 } });
            for (0..3) |_| {
                try ui.open(null, .{ .layout = .{ .sizing = .fixed(3) }, .background_color = .black, .corner_radius = .uniform(2) });
                ui.close();
            }
            ui.close();
        },
    }
}

fn moreView(ui: *app.Ui) !void {
    const on = ui.messages(Root);
    try ui.open("more-menu", .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .init(12, 12, 4, 4) } });
    defer ui.close();
    const destinations = .{
        .{ "more-downloads", "Download queue", lib.Screen.queue },
        .{ "more-storage", "Manage storage", lib.Screen.storage },
        .{ "more-categories", "Categories", lib.Screen.categories },
        .{ "more-stats", "Statistics", lib.Screen.stats },
        .{ "more-backup", "Backup and restore", lib.Screen.backup },
        .{ "more-trackers", "Trackers", lib.Screen.trackers },
        .{ "more-upcoming", "Upcoming", lib.Screen.upcoming },
        .{ "more-library-settings", "Library settings", lib.Screen.engine_settings },
    };
    inline for (destinations) |destination| try moreRow(ui, destination[0], destination[1], on.bind(.{ .act = @as(lib.Action, .{ .feed = destination[2] }) }));
    try moreRow(ui, "more-reading-settings", "Reading settings", on.bind(.reading_settings));
    try moreRow(ui, "more-scan-local", "Scan local manga", on.bind(.{ .online = .scan }));
    ui.spacer();
    try moreRow(ui, "more-quit", "Close PocketManga", on.bind(.quit));
}

fn moreRow(ui: *app.Ui, key: anytype, label: []const u8, action: app.Action) !void {
    try ui.open(key, .{
        .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(32) }, .padding = .init(8, 8, 0, 0), .child_alignment = .center_left },
        .background_color = if (ui.pressed(key)) .gray(218) else .white,
        .on_click = action,
        .focusable = true,
    });
    defer ui.close();
    try text(ui, label, 15, 0);
}

pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
    const session = @constCast(ui.use(Session));
    session.beginCoverFrame();
    const model = session.model;
    const on = ui.messages(Root);
    if (session.browser.busy != null) try ui.every("network-poll", .fromMilliseconds(200), on.bind(.poll)) else if (model.screen == .queue or (if (session.browser.engine) |engine| engine.queue.running() else false)) try ui.every("queue-poll", .fromMilliseconds(2000), on.bind(.poll));
    if (!state.focused) try ui.after("initial-focus", .fromMilliseconds(0), on.bind(.focus));
    try ui.open("screen", .{
        .layout = .{ .sizing = .grow(.{}), .axis = .y },
        .background_color = .white,
        .focus = .{ .on_key = on.handler(.key), .keys = .{ .typing = false, .escape = true } },
    });
    defer ui.close();
    const navigation = if (session.storage_managing) null else rootNavigation(model.screen, state.more_root);
    if (model.screen != .reader) try toolbar(ui, session, navigation);
    if (session.download_error and session.browser.busy == null) {
        try ui.open("download-error", .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = .all(10), .child_gap = 5 }, .border = .{ .color = .black, .widths = .outside(2) } });
        try text(ui, if (session.download_blocked) "Cannot download from this source" else if (session.download_canceled) "Download canceled - tap chapter to resume" else "Download failed - tap chapter to resume", 15, 0);
        if (session.download_identity) |identity| try text(ui, identity.chapter, 14, 0);
        if (session.download_blocked) try ui.text(session.status, .{ .font_size = 13, .wrap_mode = .words }) else try text(ui, session.status, 13, 0);
        ui.close();
    }
    if (session.browser.busy) |job| {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 16 } });
        defer ui.close();
        try text(ui, if (job.request == .download) "Downloading chapter" else "Working on your reader", 18, 0);
        if (job.request == .download) if (session.download_identity) |identity| {
            try downloadIdentity(ui, identity.series, identity.chapter);
        };
        const total = job.pages_total.load(.acquire);
        var extension_buf: [64]u8 = undefined;
        try text(ui, switch (job.phase.load(.acquire)) {
            .starting => "Loading libtachi worker... (this may take a minute)",
            .extension_loading => try ui.fmt("Loading {s} extension...", .{job.extensionLoading(&extension_buf)}),
            .operation => switch (job.request) {
                .sources => "Loading extensions...",
                .extensions => "Loading extension repository...",
                .install => "Downloading and installing extension...",
                .uninstall => "Removing extension...",
                .browse => if (session.browser.source_name.len > 0) try ui.fmt("Loading {s}...", .{session.browser.source_name}) else "Loading titles...",
                .download => if (total == 0) "Fetching page list" else "Downloading pages",
                .read => if (total == 0) "Fetching page list" else "Loading pages",
                .scan_local => "Scanning local manga...",
                .global_search => "Searching sources...",
                .migrate => "Migrating...",
                .export_backup => "Creating backup...",
                .import_backup => "Restoring backup...",
                .export_downloads => "Exporting downloads...",
                .import_downloads => "Importing downloads...",
                .update_library => "Updating library...",
                .preferences, .set_preference => "Loading source settings...",
                else => "Updating chapter lists...",
            },
        }, 13, 40);
        if (total > 0) try ui.print(.{ .font_size = 14 }, "{d} / {d} pages", .{ job.pages_done.load(.acquire), total });
        try onlineButton(ui, "cancel-job", "Cancel", .cancel);
    } else switch (model.screen) {
        .library, .chapters => try list(ui, model),
        .reader => try reader(ui, session),
        .settings => if (state.more_root) try moreView(ui) else {
            try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 16 } });
            defer ui.close();
            try text(ui, "Reading direction", 15, 0);
            try button(ui, "direction", if (model.prefs.rtl) "Right to left (manga)" else "Left to right", .rtl);
            try text(ui, "Page refresh", 15, 0);
            try button(ui, "refresh", if (model.prefs.full_refresh) "Full refresh on each page" else "Partial (periodic cleaning)", .refresh);
            try text(ui, "Physical Next always advances a page.", 12, 60);
            try text(ui, "Direction changes the left / right tap zones.", 12, 60);
            {
                try ui.open(null, .{ .layout = .{ .child_gap = 8 } });
                defer ui.close();
                try onlineButton(ui, "scan-local", "Scan local manga", .scan);
                try button(ui, "stats", "Statistics", .{ .feed = .stats });
            }
            {
                try ui.open(null, .{ .layout = .{ .child_gap = 8 } });
                defer ui.close();
                try button(ui, "engine-settings", "Library settings", .{ .feed = .engine_settings });
                try button(ui, "categories", "Categories", .{ .feed = .categories });
            }
            {
                try ui.open(null, .{ .layout = .{ .child_gap = 8 } });
                defer ui.close();
                try button(ui, "backup", "Backup and restore", .{ .feed = .backup });
                try button(ui, "trackers", "Trackers", .{ .feed = .trackers });
            }
            ui.spacer();
            try app.widgets.button(ui, "quit", .{ .label = "Close PocketManga", .on_click = on.bind(.quit) });
        },
        .sources, .extensions, .catalog, .source_settings, .global_search, .languages => try browserView(ui, session),
        .updates, .history, .queue, .upcoming => try feedView(ui, session),
        .chapter_menu, .title_menu => try menuView(ui, model),
        .title_options => try titleOptionsView(ui, session),
        .engine_settings => try settingsView(ui, session),
        .stats => try statsView(ui, session),
        .storage => try storageView(ui, session, state),
        .stores => try storesView(ui, session),
        .trackers, .tracker_login, .tracking, .track_search => try trackingView(ui, session),
        .duplicate => try duplicateView(ui, session),
        .backup => try backupView(ui, session),
        .categories => try categoriesView(ui, model),
    }
    if (model.screen == .reader and model.reader_controls) try toolbar(ui, session, navigation);
    if (session.status.len > 0 and model.screen != .reader and !session.download_error and session.browser.busy == null) try text(ui, session.status, 11, 0);
    if (session.cover_job != null) try ui.every("cover-poll", .fromMilliseconds(200), on.bind(.poll));
    if (navigation) |selected| try navigationBar(ui, selected, session.browser.busy == null);
}
fn toolbar(ui: *app.Ui, session: *const Session, navigation: ?Navigation) !void {
    const model = session.model;
    {
        try ui.open("toolbar", .{ .floating = if (model.screen == .reader) .{ .mode = .root } else .{}, .background_color = .white, .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(48) }, .padding = .init(12, 12, 4, 4), .child_gap = 8, .child_alignment = .center_left }, .border = .{ .color = .gray(220), .widths = .{ .bottom = 1 } } });
        defer ui.close();
        if (navigation == null and session.browser.busy == null) try button(ui, "back", "Back", .back);
        try text(ui, switch (model.screen) {
            .library => if (session.storage_managing) "Downloaded titles" else "Library",
            .chapters => "Chapters",
            .reader => "Reader",
            .settings => if (navigation == .more) "More" else "Settings",
            .sources => "Browse",
            .extensions => "Browse",
            .catalog => "Browse",
            .source_settings => "Source settings",
            .updates => "Updates",
            .history => "History",
            .queue => "Downloads",
            .chapter_menu => "Chapter",
            .title_menu => "Title",
            .engine_settings => "Library settings",
            .backup => "Backup",
            .categories => "Categories",
            .global_search => if (session.browser.migrate_from != null) "Migrate to" else "Search all",
            .languages => "Languages",
            .stores => "Extension stores",
            .trackers => "Trackers",
            .tracker_login => "Log in",
            .tracking => "Tracking",
            .track_search => "Find on tracker",
            .stats => "Statistics",
            .storage => "Storage",
            .duplicate => "Already in library?",
            .title_options => "Chapter options",
            .upcoming => "Upcoming",
        }, 22, 0);
        ui.spacer();
        if (navigation == null and model.screen != .settings and session.browser.busy == null) try button(ui, "settings", "Aa", .settings);
    }
}
fn storageView(ui: *app.Ui, session: *const Session, state: *const State) !void {
    const on = ui.messages(Root);
    const engine = session.browser.engine orelse {
        try text(ui, "Storage is unavailable", 15, 0);
        return;
    };
    try ui.task("storage-inspection", .{ .restart = state.storage_revision }, storage.inspect, .{engine}, on.handler(.storage_loaded));
    if (state.storage_clearing) try ui.task("clear-online-cache", .{}, storage.clearCache, .{engine}, on.handler(.storage_cleared));
    try ui.open("storage-content", .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 10 } });
    defer ui.close();
    try text(ui, "New downloads", 18, 0);
    const selected_sd = session.settings.downloads.storage == .sd_card;
    try app.widgets.button(ui, "storage-internal", .{ .label = if (selected_sd) "[ ] Internal storage" else "[x] Internal storage", .on_click = on.bind(.{ .storage_action = .internal }) });
    const sd_available = if (state.storage_snapshot) |snapshot| snapshot.sd_card.present else false;
    try app.widgets.button(ui, "storage-sd", .{ .label = if (selected_sd) "[x] SD card" else "[ ] SD card", .enabled = sd_available, .on_click = on.bind(.{ .storage_action = .sd_card }) });
    try ui.text("Existing downloads stay on their original storage. Interrupted downloads resume there.", .{ .font_size = 12, .wrap_mode = .words });
    if (state.storage_snapshot) |snapshot| {
        inline for (.{ .{ "Internal", snapshot.internal }, .{ "SD card", snapshot.sd_card } }) |item| {
            if (!item[1].present) {
                try ui.print(.{ .font_size = 13 }, "{s}: not inserted or unavailable", .{item[0]});
            } else {
                try ui.print(.{ .font_size = 13 }, "{s}: {d} MiB of downloads", .{ item[0], item[1].bytes / (1 << 20) });
                if (item[1].available) |bytes| try ui.print(.{ .font_size = 12 }, "{d} MiB available", .{bytes / (1 << 20)});
            }
        }
    } else try text(ui, "Checking storage...", 13, 0);
    try app.widgets.button(ui, "storage-manage", .{ .label = "Manage downloaded chapters", .on_click = on.bind(.{ .storage_action = .manage }) });
    try app.widgets.button(ui, "storage-clear-cache", .{ .label = if (state.storage_clearing) "Clearing cache..." else "Clear online reading cache", .enabled = !state.storage_clearing and !engine.queue.running(), .on_click = on.bind(.{ .storage_action = .clear_cache }) });
}

fn list(ui: *app.Ui, model: *const lib.Model) !void {
    const is_library = model.screen == .library;
    const count = if (is_library) model.titleCount() else model.chapterCount();
    const on = ui.messages(Root);
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = .init(12, 12, 4, 6), .child_gap = 5 } });
        defer ui.close();
        if (is_library) {
            {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 8, .child_alignment = .center_left } });
                defer ui.close();
                try app.widgets.searchField(ui, "query", .{ .text = model.query_text, .placeholder = "Search library", .on_change = on.handler(.query), .sizing = .{ .width = .fixed(160) } });
                if (model.library.manga.len > 0) try onlineButton(ui, "update-library", "Update", .update_all);
                try app.widgets.button(ui, "library-layout", .{ .label = if (model.prefs.library_grid) "List" else "Grid", .on_click = on.bind(.library_grid) });
            }
            if (model.categories.len > 1) {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 12, .child_alignment = .center_left }, .border = .{ .color = .gray(220), .widths = .{ .bottom = 1 } } });
                defer ui.close();
                // Show adjacent categories as tabs while keeping every category reachable.
                const first = model.category -| 1;
                if (first > 0) try app.widgets.button(ui, "previous-category", .{ .label = "<", .on_click = on.bind(.{ .act = @as(lib.Action, .{ .category = -1 }) }) });
                for (first..@min(first + 3, model.categories.len)) |i| {
                    const selected = i == model.category;
                    try ui.open(.{ .category_tab = i }, .{
                        .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .init(2, 2, 5, 5) },
                        .border = .{ .color = .black, .widths = .{ .bottom = if (selected) 2 else 0 } },
                        .on_click = on.bind(.{ .act = @as(lib.Action, .{ .category = @as(i32, @intCast(i)) - @as(i32, @intCast(model.category)) }) }),
                    });
                    try text(ui, model.categories[i], 13, if (selected) 0 else 90);
                    ui.close();
                }
                ui.spacer();
                if (first + 3 < model.categories.len) try app.widgets.button(ui, "next-category", .{ .label = ">", .on_click = on.bind(.{ .act = @as(lib.Action, .{ .category = 1 }) }) });
            } else try ui.print(.{ .font_size = 11, .color = .gray(90) }, "{d} {s}", .{ count, if (count == 1) "title" else "titles" });
        } else {
            const manga = model.library.manga[model.manga];
            const title_style: f.layout.text.Style = .{ .font_size = 17, .font_weight = .bold, .wrap_mode = .words, .overflow = .ellipsis_end };
            const title_lines = try ui.core.make_lines(ui.core, manga.title, title_style, @max(1, ui.core.viewport.x - 84));
            const shown_lines = if (model.title_expanded) title_lines.len else @min(2, title_lines.len);
            const title_height: f32 = @floatFromInt(@max(1, shown_lines) * 21);
            const header_height = @max(72, title_height + 30);
            // Keep pagination in step with the space the expanded title consumes.
            const current_session = ui.use(Session);
            const banner_height: f32 = if (current_session.download_error and current_session.browser.busy == null) blk: {
                const status_lines = if (current_session.download_blocked) (try ui.core.make_lines(ui.core, current_session.status, .{ .font_size = 13, .wrap_mode = .words }, @max(1, ui.core.viewport.x - 20))).len else 1;
                break :blk 43 + @as(f32, @floatFromInt(status_lines)) * 15.6 + @as(f32, if (current_session.download_identity != null) 22 else 0);
            } else 0;
            const available_rows = @max(1, @min(lib.Model.rows, @as(usize, @intFromFloat(@max(34, ui.core.viewport.y - 190 - header_height - banner_height) / 34))));
            @constCast(model).chapter_page_rows = available_rows;
            {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(header_height) }, .child_gap = 12 } });
                defer ui.close();
                {
                    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(48), .height = .fixed(72) }, .child_alignment = .center }, .background_color = .gray(238), .corner_radius = .uniform(3) });
                    defer ui.close();
                    const session = @constCast(ui.use(Session));
                    if (session.coverImage(manga)) |image| ui.content(&image.content) else try text(ui, "Manga", 10, 110);
                }
                {
                    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(@max(1, ui.core.viewport.x - 84)) }, .axis = .y, .child_gap = 3 } });
                    defer ui.close();
                    try ui.open("series-title", .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(title_height) }, .axis = .y }, .on_click = on.bind(.{ .act = .toggle_title }) });
                    if (!model.title_expanded and title_lines.len > 2) {
                        const line_style = title_style.with(.{ .wrap_mode = .none });
                        try ui.text(manga.title[0..title_lines[0].end], line_style);
                        try ui.text(manga.title[title_lines[1].start..], line_style);
                    } else try ui.text(manga.title, title_style);
                    ui.close();
                    if (manga.author.len > 0) try text(ui, manga.author, 12, 80);
                    try text(ui, if (manga.local()) "Local manga" else if (manga.favorite) "In library" else "Online manga", 10, 90);
                }
            }
            {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 8, .child_alignment = .center_left } });
                defer ui.close();
                try ui.print(.{ .font_size = 12, .color = .gray(70) }, "{d} {s}", .{ count, if (count == 1) "chapter" else "chapters" });
                ui.spacer();
                const flags: tachi.views.ChapterFlags = .decode(manga.chapter_flags);
                try app.widgets.button(ui, "chapter-direction", .{ .label = if (flags.ascending) "Oldest first" else "Newest first", .on_click = on.bind(.{ .edit = .chapter_direction }) });
                try app.widgets.button(ui, "jump-chapter", .{ .label = "Jump", .enabled = count > 0, .on_click = on.bind(.jump_chapter) });
            }
            if (manga.source_id != null) {
                try ui.open(null, .{ .layout = .{ .child_gap = 8 } });
                defer ui.close();
                try onlineButton(ui, "refresh-chapters", "Refresh chapters", .refresh_book);
                try onlineButton(ui, "queue-unread", "Queue unread", .queue_unread);
            }
        }
    }
    const page_rows = model.pageRows();
    {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .x(12), .child_gap = 1 } });
        defer ui.close();
        if (count == 0) {
            ui.spacer();
            try text(ui, if (model.query_text.len > 0) "No matching titles" else "Your library is empty", 18, 0);
            try text(ui, "Find something to read in Browse.", 12, 80);
            try text(ui, "Local folders can be scanned in More.", 12, 80);
        }
        if (is_library and model.prefs.library_grid and count > 0) try libraryGrid(ui, model) else for (@min(model.offset, count)..@min(model.offset + page_rows, count)) |row| {
            const i = if (is_library) model.titleIndex(row) else model.chapterIndex(row);
            const title = if (is_library) model.library.manga[i].title else model.library.manga[model.manga].chapters[i].title;
            const key = .{ .row = i };
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_alignment = .center_left } });
            defer {
                app.widgets.button(ui, .{ .menu = i }, .{ .label = "...", .on_click = on.bind(.{ .act = @as(lib.Action, .{ .menu = i }) }) }) catch {};
                ui.close();
            }
            try ui.open(key, .{
                .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(if (is_library) 48 else 34) }, .axis = .y, .padding = .init(2, 6, 3, 3), .child_gap = 2 },
                .background_color = rowFill(ui, key),
                .on_click = on.bind(.{ .act = if (is_library) @as(lib.Action, .{ .open = i }) else @as(lib.Action, .{ .read = i }) }),
            });
            if (is_library) {
                const manga = model.library.manga[i];
                const counts = manga.counts();
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(30) }, .axis = .y } });
                const style: f.layout.text.Style = .{ .font_size = 12, .font_weight = .bold, .wrap_mode = .words, .overflow = .ellipsis_end };
                const lines = try ui.core.make_lines(ui.core, title, style, @max(1, ui.core.viewport.x - 68));
                if (lines.len > 2) {
                    const single = style.with(.{ .wrap_mode = .none });
                    try ui.text(title[0..lines[0].end], single);
                    try ui.text(title[lines[1].start..], single);
                } else try ui.text(title, style);
                ui.close();
                try ui.print(.{ .font_size = 10, .color = .gray(90) }, "{d} unread  ·  {s}", .{ counts.unread, manga.author });
            } else {
                const ch = model.library.manga[model.manga].chapters[i];
                const state = model.readState(ch);
                const gray: u8 = if (state.read) 120 else 0;
                const session = ui.use(Session);
                const saved = if (i < session.chapter_downloads.len) session.chapter_downloads[i] else null;
                const total = if (ch.pages.len > 0) ch.pages.len else if (saved) |p| p.total else if (model.online_chapter != null and std.mem.eql(u8, model.online_chapter.?, ch.id)) model.online_pages.len else @as(usize, ch.page_count);
                const reading = if (state.started and !state.read) (if (total > 0) try ui.fmt("Reading {d}/{d}", .{ @min(@as(usize, state.page) + 1, total), total }) else try ui.fmt("Reading {d}/?", .{@as(usize, state.page) + 1})) else if (state.read) "Read" else "";
                const downloaded = if (saved) |p| try ui.fmt("Resume {d}/{d}", .{ p.done, p.total }) else if (ch.downloaded()) "Downloaded" else "Not downloaded";
                const progress = if (reading.len > 0) (if (saved != null) try ui.fmt("{s} · {s}", .{ reading, downloaded }) else reading) else downloaded;
                try text(ui, title, 14, gray);
                try ui.print(.{ .font_size = 10, .color = .gray(if (state.read) 130 else 90), .overflow = .ellipsis_end, .wrap_mode = .none }, "{s}{s}{s}{s}", .{
                    if (ch.bookmark) "Bookmarked · " else "",
                    progress,
                    if (ch.scanlator != null) " · " else "",
                    ch.scanlator orelse "",
                });
            }
            ui.close();
        }
        if (!(is_library and model.prefs.library_grid and count > 0)) ui.spacer();
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .init(12, 12, 4, 4), .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try app.widgets.button(ui, "previous-list", .{ .label = "Previous", .enabled = model.offset > 0, .on_click = on.bind(.{ .act = @as(lib.Action, .{ .list_page = -1 }) }) });
        ui.spacer();
        try ui.print(.{ .font_size = 11, .color = .gray(90) }, "{d}/{d}", .{ if (count == 0) @as(usize, 0) else model.offset / page_rows + 1, (count + page_rows - 1) / page_rows });
        ui.spacer();
        try app.widgets.button(ui, "next-list", .{ .label = "Next", .enabled = model.offset + page_rows < count, .on_click = on.bind(.{ .act = @as(lib.Action, .{ .list_page = 1 }) }) });
    }
}
/// Comfortable cover cards mirror Mihon's library with full-size portraits on e-ink.
fn libraryGrid(ui: *app.Ui, model: *const lib.Model) !void {
    const session = @constCast(ui.use(Session));
    const on = ui.messages(Root);
    const end = @min(model.offset + model.pageRows(), model.titleCount());
    var row = @min(model.offset, end);
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .child_gap = 8 } });
    defer ui.close();
    // A single row keeps portrait covers large; paging replaces Android scrolling.
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(250) }, .child_gap = 12 } });
        defer ui.close();
        for (0..2) |_| {
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(148) }, .axis = .y, .child_gap = 3 } });
            defer ui.close();
            if (row >= end) continue;
            const i = model.titleIndex(row);
            row += 1;
            const manga = model.library.manga[i];
            const counts = manga.counts();
            const key = .{ .row = i };
            {
                try ui.open(key, .{
                    .layout = .{ .sizing = .grow(.{}), .axis = .y, .child_gap = 4 },
                    .background_color = rowFill(ui, key),
                    .on_click = on.bind(.{ .act = @as(lib.Action, .{ .open = i }) }),
                });
                defer ui.close();
                {
                    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(148), .height = .fixed(190) }, .child_alignment = .center }, .background_color = .gray(238), .corner_radius = .uniform(4) });
                    defer ui.close();
                    if (session.coverImage(manga)) |image| ui.content(&image.content) else {
                        try ui.open(null, .{ .layout = .{ .axis = .y, .child_alignment = .center, .child_gap = 4 } });
                        defer ui.close();
                        try text(ui, "NO COVER", 10, 110);
                        try text(ui, if (manga.local()) "Local manga" else "Manga", 11, 90);
                    }
                }
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(148), .height = .fixed(30) }, .axis = .y } });
                const style: f.layout.text.Style = .{ .font_size = 12, .font_weight = .bold, .wrap_mode = .words, .overflow = .ellipsis_end };
                const lines = try ui.core.make_lines(ui.core, manga.title, style, 148);
                if (lines.len > 2) {
                    const single = style.with(.{ .wrap_mode = .none });
                    try ui.text(manga.title[0..lines[0].end], single);
                    try ui.text(manga.title[lines[1].start..], single);
                } else try ui.text(manga.title, style);
                ui.close();
            }
            {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_alignment = .center_left, .child_gap = 4 } });
                defer ui.close();
                if (counts.unread > 0) try ui.print(.{ .font_size = 10, .color = .black }, "{d} unread", .{counts.unread});
                if (counts.downloaded > 0) try ui.print(.{ .font_size = 10, .color = .gray(80) }, "{d} saved", .{counts.downloaded});
                ui.spacer();
                try ui.open(.{ .menu = i }, .{
                    .layout = .{ .sizing = .{ .width = .fixed(24), .height = .fixed(20) }, .child_alignment = .center },
                    .on_click = on.bind(.{ .act = @as(lib.Action, .{ .menu = i }) }),
                });
                try text(ui, "...", 15, 60);
                ui.close();
            }
        }
    }
}
/// libtachi's settings, one row each: checks for switches, values for the rest.
fn settingsView(ui: *app.Ui, session: *const Session) !void {
    const model = session.model;
    const s = session.settings;
    const on = ui.messages(Root);
    const settings = std.enums.values(lib.Setting);
    {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(10), .child_gap = 8 } });
        defer ui.close();
        for (settings[@min(model.offset, settings.len)..@min(model.offset + lib.Model.rows, settings.len)]) |which| {
            const check = struct {
                fn mark(on_: bool) []const u8 {
                    return if (on_) "[x]" else "[ ]";
                }
            }.mark;
            const sort = session.currentSort();
            const label = switch (which) {
                .skip_completed => try ui.fmt("{s} Update: skip completed titles", .{check(s.update.skip_completed)}),
                .skip_unread => try ui.fmt("{s} Update: skip titles with unread chapters", .{check(s.update.skip_unread)}),
                .skip_not_started => try ui.fmt("{s} Update: skip titles not started", .{check(s.update.skip_not_started)}),
                .skip_not_due => try ui.fmt("{s} Update: skip titles not due", .{check(s.update.skip_outside_release_period)}),
                .update_details => try ui.fmt("{s} Update: refresh details too", .{check(s.update.metadata)}),
                .download_new => try ui.fmt("{s} Download new chapters", .{check(s.downloads.new_chapters)}),
                .delete_marked_read => try ui.fmt("{s} Delete downloads marked read", .{check(s.downloads.remove_after_marked_read)}),
                .delete_bookmarked => try ui.fmt("{s} Allow deleting bookmarked", .{check(s.downloads.remove_bookmarked)}),
                .delete_after_reading => switch (s.downloads.remove_after_read_slots) {
                    -1 => "After reading: keep downloads",
                    0 => "After reading: delete that chapter",
                    else => |n| try ui.fmt("After reading: delete {d} behind", .{n}),
                },
                .download_ahead => if (s.downloads.ahead == 0) "While reading: download nothing ahead" else try ui.fmt("While reading: download {d} ahead", .{s.downloads.ahead}),
                .skip_read => try ui.fmt("{s} Reader: skip read chapters", .{check(s.reader.skip_read)}),
                .skip_filtered => try ui.fmt("{s} Reader: skip filtered chapters", .{check(s.reader.skip_filtered)}),
                .skip_duplicates => try ui.fmt("{s} Reader: skip duplicate chapters", .{check(s.reader.skip_duplicates)}),
                .incognito => try ui.fmt("{s} Incognito (no progress or history)", .{check(s.reader.incognito)}),
                .downloaded_only => try ui.fmt("{s} Downloaded only", .{check(s.library.downloaded_only)}),
                .sort_mode => try ui.fmt("Sort: {s}", .{@tagName(sort.mode)}),
                .sort_ascending => if (sort.ascending) "Order: ascending" else "Order: descending",
            };
            try app.widgets.button(ui, .{ .setting = which }, .{ .label = label, .on_click = on.bind(.{ .setting = which }) });
        }
        ui.spacer();
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(8), .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try app.widgets.button(ui, "previous-settings", .{ .label = "Previous", .enabled = model.offset > 0, .on_click = on.bind(.{ .act = @as(lib.Action, .{ .list_page = -1 }) }) });
        ui.spacer();
        try app.widgets.button(ui, "next-settings", .{ .label = "Next", .enabled = model.offset + lib.Model.rows < settings.len, .on_click = on.bind(.{ .act = @as(lib.Action, .{ .list_page = 1 }) }) });
    }
}

/// How a title's chapters are listed and updated.
fn titleOptionsView(ui: *app.Ui, session: *const Session) !void {
    const model = session.model;
    const manga = model.library.manga[model.manga];
    const flags: tachi.views.ChapterFlags = .decode(manga.chapter_flags);
    const on = ui.messages(Root);
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 8 } });
    defer ui.close();
    try text(ui, manga.title, 16, 0);
    const tri = struct {
        fn name(state: tachi.views.TriState, yes: []const u8, no: []const u8) []const u8 {
            return switch (state) {
                .disabled => "all",
                .include => yes,
                .exclude => no,
            };
        }
    }.name;
    const sort = switch (flags.sort) {
        .source => "source order",
        .number => "chapter number",
        .upload => "upload date",
        .alphabetical => "name",
    };
    const Choice = struct { label: []const u8, edit: Session.Edit };
    for ([_]Choice{
        .{ .label = try ui.fmt("Sort by {s}", .{sort}), .edit = .chapter_sort },
        .{ .label = if (flags.ascending) "Oldest first" else "Newest first", .edit = .chapter_direction },
        .{ .label = try ui.fmt("Read: {s}", .{tri(flags.unread, "unread only", "read only")}), .edit = .filter_unread },
        .{ .label = try ui.fmt("Downloads: {s}", .{tri(flags.downloaded, "downloaded only", "not downloaded")}), .edit = .filter_downloaded },
        .{ .label = try ui.fmt("Bookmarks: {s}", .{tri(flags.bookmarked, "bookmarked only", "not bookmarked")}), .edit = .filter_bookmarked },
        .{ .label = if (manga.fetch_interval < 0) try ui.fmt("Update every {d} days", .{-manga.fetch_interval}) else if (manga.fetch_interval > 0) try ui.fmt("Update every {d} days (estimated)", .{manga.fetch_interval}) else "Update interval: estimated", .edit = .interval },
    }, 0..) |choice, n| try app.widgets.button(ui, .{ .option = n }, .{ .label = choice.label, .on_click = on.bind(.{ .edit = choice.edit }) });
    const groups = try session.scanlators(ui.arena());
    if (groups.len > 0) try text(ui, "Scanlation groups", 14, 0);
    for (groups, 0..) |group, i| {
        const excluded = manga.excludes(group);
        try app.widgets.button(ui, .{ .group = i }, .{ .label = try ui.fmt("{s} {s}", .{ if (excluded) "[ ]" else "[x]", group }), .on_click = on.bind(.{ .edit = @as(Session.Edit, .{ .toggle_scanlator = @intCast(i) }) }) });
    }
}

/// libtachi's extension stores: add one by URL, remove, refresh.
fn storesView(ui: *app.Ui, session: *const Session) !void {
    const on = ui.messages(Root);
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(10), .child_gap = 8 } });
    defer ui.close();
    try app.widgets.searchField(ui, "store-url", .{ .text = "", .placeholder = "Add a store by its index URL", .on_change = on.handler(.add_store) });
    try onlineButton(ui, "refresh-stores", "Refresh stores", .refresh_stores);
    if (session.stores.len == 0) try text(ui, "No stores: extensions come from the default repository.", 12, 40);
    for (session.stores, 0..) |store, i| {
        try ui.open(.{ .store = i }, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 6, .child_alignment = .center_left } });
        defer ui.close();
        {
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y } });
            defer ui.close();
            try text(ui, if (store.name.len > 0) store.name else store.index_url, 14, 0);
            try text(ui, store.index_url, 10, 60);
        }
        try onlineButton(ui, .{ .remove_store = i }, "Remove", .{ .remove_store = i });
    }
}

/// Trackers to log in to, a title's tracks, and search results to bind.
fn trackingView(ui: *app.Ui, session: *const Session) !void {
    const model = session.model;
    const on = ui.messages(Root);
    const state = session.trackers;
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(10), .child_gap = 8 } });
    defer ui.close();
    switch (model.screen) {
        .trackers => for (tachi.tracking.trackers) |t| {
            try ui.open(.{ .tracker = t.id }, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 6, .child_alignment = .center_left } });
            defer ui.close();
            const c = state.credential(t.id);
            try text(ui, if (state.loggedIn(t.id)) try ui.fmt("{s}: {s}", .{ t.name, if (c.display_name.len > 0) c.display_name else "logged in" }) else t.name, 14, 0);
            ui.spacer();
            if (state.loggedIn(t.id)) {
                try app.widgets.button(ui, .{ .logout = t.id }, .{ .label = "Log out", .on_click = on.bind(.{ .track = @as(Session.TrackEdit, .{ .logout = t.id }) }) });
            } else {
                try app.widgets.button(ui, .{ .login = t.id }, .{ .label = if (t.enhanced) "Enable" else "Log in", .on_click = on.bind(.{ .track = @as(Session.TrackEdit, .{ .login = t.id }) }) });
            }
        },
        .tracker_login => {
            const t = tachi.tracking.get(session.tracker_id) orelse return;
            try text(ui, t.name, 16, 0);
            try app.widgets.searchField(ui, "login-user", .{ .text = session.login_username, .placeholder = "Username", .on_change = on.handler(.login_user) });
            try app.widgets.searchField(ui, "login-password", .{ .text = "", .placeholder = "Password (logs in)", .on_change = on.handler(.login_password) });
            try text(ui, "Services that log in through a browser need their code or token as the password.", 12, 40);
        },
        .tracking => {
            const manga = model.library.manga[model.manga];
            try text(ui, manga.title, 16, 0);
            var any = false;
            for (tachi.tracking.trackers) |t| {
                if (!state.loggedIn(t.id)) continue;
                any = true;
                const bound = for (manga.tracks) |tr| {
                    if (tr.tracker_id == t.id) break tr;
                } else null;
                try ui.open(.{ .tracked = t.id }, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .child_gap = 4 } });
                defer ui.close();
                if (bound) |tr| {
                    const status = for (t.statuses) |st| {
                        if (st.value == tr.status) break st.name;
                    } else "?";
                    try text(ui, try ui.fmt("{s}: {s}", .{ t.name, tr.title }), 14, 0);
                    try ui.print(.{ .font_size = 11, .color = .gray(60) }, "{s}, chapter {d}{s}{s}", .{ status, tr.last_chapter_read, if (tr.total_chapters > 0) try ui.fmt(" of {d}", .{tr.total_chapters}) else "", if (t.scoreCount(state.formats) > 0) try ui.fmt(", score {s}", .{try t.displayScore(ui.arena(), state.formats, tr.score)}) else "" });
                    try ui.open(null, .{ .layout = .{ .child_gap = 6 } });
                    defer ui.close();
                    try app.widgets.button(ui, .{ .status = t.id }, .{ .label = "Status", .on_click = on.bind(.{ .track = @as(Session.TrackEdit, .{ .status = t.id }) }) });
                    if (t.scoreCount(state.formats) > 0) try app.widgets.button(ui, .{ .score = t.id }, .{ .label = "Score", .on_click = on.bind(.{ .track = @as(Session.TrackEdit, .{ .score = t.id }) }) });
                    try app.widgets.button(ui, .{ .refresh = t.id }, .{ .label = "Refresh", .on_click = on.bind(.{ .track = @as(Session.TrackEdit, .{ .refresh = t.id }) }) });
                    try app.widgets.button(ui, .{ .unbind = t.id }, .{ .label = "Remove", .on_click = on.bind(.{ .track = @as(Session.TrackEdit, .{ .unbind = t.id }) }) });
                } else {
                    try ui.open(null, .{ .layout = .{ .child_gap = 6, .child_alignment = .center_left } });
                    defer ui.close();
                    try text(ui, t.name, 14, 0);
                    try app.widgets.button(ui, .{ .search = t.id }, .{ .label = "Find", .on_click = on.bind(.{ .track = @as(Session.TrackEdit, .{ .search = t.id }) }) });
                }
            }
            if (!any) try text(ui, "Log in to a tracker in Settings first.", 13, 40);
        },
        .track_search => {
            const job = session.browser.tracking orelse return;
            const matches = job.result.tracking_reply.matches;
            if (matches.len == 0) try text(ui, "Nothing found", 14, 60);
            for (matches[0..@min(matches.len, lib.Model.rows)], 0..) |m, i| {
                const key = .{ .match = i };
                try ui.open(key, .{
                    .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(37) }, .axis = .y, .padding = .init(8, 8, 3, 3) },
                    .background_color = rowFill(ui, key),
                    .border = .{ .color = .gray(130), .widths = .{ .bottom = 1 } },
                    .on_click = on.bind(.{ .track = @as(Session.TrackEdit, .{ .bind = i }) }),
                });
                defer ui.close();
                try text(ui, m.track.title, 14, 0);
                try text(ui, if (m.publishing_type.len > 0) m.publishing_type else m.start_date, 10, 60);
            }
        },
        else => {},
    }
}

/// libtachi's library statistics.
fn statsView(ui: *app.Ui, session: *const Session) !void {
    const s = session.stats;
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 8 } });
    defer ui.close();
    try ui.print(.{ .font_size = 15 }, "{d} titles, {d} completed, {d} started, {d} local", .{ s.titles, s.completed, s.started, s.local });
    try ui.print(.{ .font_size = 15 }, "{d} of {d} chapters read", .{ s.read_chapters, s.chapters });
    try ui.print(.{ .font_size = 15 }, "{d} chapters downloaded", .{s.downloaded_chapters});
    const minutes = @divFloor(s.read_ms, std.time.ms_per_min);
    try ui.print(.{ .font_size = 15 }, "{d} h {d} min read", .{ @divFloor(minutes, 60), @mod(minutes, 60) });
    try ui.print(.{ .font_size = 15 }, "{d} titles a library update checks", .{s.update_candidates});
}

/// Mihon's question before adding a title the library may already have.
fn duplicateView(ui: *app.Ui, session: *const Session) !void {
    const pending = session.pending_add orelse return;
    const on = ui.messages(Root);
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 10 } });
    defer ui.close();
    try text(ui, pending.manga.title, 16, 0);
    try text(ui, "Your library has a title like this:", 13, 40);
    for (pending.matches) |name| try text(ui, name, 14, 0);
    try app.widgets.button(ui, "add-anyway", .{ .label = "Add anyway", .on_click = on.bind(.{ .confirm_add = true }) });
    try app.widgets.button(ui, "dont-add", .{ .label = "Don't add", .on_click = on.bind(.{ .confirm_add = false }) });
}

/// Backups to create and restore, and a Mihon downloads folder to swap.
fn backupView(ui: *app.Ui, session: *const Session) !void {
    const model = session.model;
    const on = ui.messages(Root);
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(10), .child_gap = 8 } });
    defer ui.close();
    try app.widgets.button(ui, "create-backup", .{ .label = "Create backup", .on_click = on.bind(.{ .backup_command = .create }) });
    try text(ui, "Backups (Mihon .tachibk) in the backups folder:", 12, 40);
    if (session.feed.len == 0) try text(ui, "None yet", 14, 60);
    for (session.feed[@min(model.offset, session.feed.len)..@min(model.offset + 4, session.feed.len)], model.offset..) |row, i| {
        try app.widgets.button(ui, .{ .backup = i }, .{ .label = try ui.fmt("Restore {s}", .{row.title}), .on_click = on.bind(.{ .restore = i }) });
    }
    try text(ui, "Mihon downloads folder (mihon-downloads):", 12, 40);
    try app.widgets.button(ui, "export-downloads", .{ .label = "Export downloads", .on_click = on.bind(.{ .backup_command = .export_downloads }) });
    try app.widgets.button(ui, "import-downloads", .{ .label = "Import downloads", .on_click = on.bind(.{ .backup_command = .import_downloads }) });
}

/// Categories in order, to move or delete, and a field to add one.
fn categoriesView(ui: *app.Ui, model: *const lib.Model) !void {
    const on = ui.messages(Root);
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(10), .child_gap = 6 } });
    defer ui.close();
    try app.widgets.searchField(ui, "new-category", .{ .text = "", .placeholder = "Add a category", .on_change = on.handler(.new_category) });
    const sorted = try ui.arena().dupe(tachi.library.Category, model.library.categories);
    const count = sorted.len;
    std.mem.sort(tachi.library.Category, sorted, {}, struct {
        fn less(_: void, x: tachi.library.Category, y: tachi.library.Category) bool {
            return x.order < y.order;
        }
    }.less);
    if (count == 0) try text(ui, "No categories", 14, 60);
    for (sorted[@min(model.offset, count)..@min(model.offset + lib.Model.rows, count)]) |category| {
        try ui.open(.{ .category_row = category.id }, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 6, .child_alignment = .center_left } });
        defer ui.close();
        try text(ui, category.name, 14, 0);
        ui.spacer();
        try app.widgets.button(ui, .{ .up = category.id }, .{ .label = "Up", .on_click = on.bind(.{ .category_edit = @as(Session.CategoryEdit, .{ .up = category.id }) }) });
        try app.widgets.button(ui, .{ .down = category.id }, .{ .label = "Down", .on_click = on.bind(.{ .category_edit = @as(Session.CategoryEdit, .{ .down = category.id }) }) });
        try app.widgets.button(ui, .{ .delete = category.id }, .{ .label = "Delete", .on_click = on.bind(.{ .category_edit = @as(Session.CategoryEdit, .{ .delete = category.id }) }) });
    }
}

/// What can be done to one chapter, or one title.
fn menuView(ui: *app.Ui, model: *const lib.Model) !void {
    const manga = model.library.manga[model.manga];
    const on = ui.messages(Root);
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 10 } });
    defer ui.close();
    try text(ui, manga.title, 16, 0);
    const Choice = struct { label: []const u8, edit: Session.Edit };
    if (model.screen == .chapter_menu) {
        const ch = manga.chapters[model.menu_chapter];
        try text(ui, ch.title, 14, 60);
        const state = model.readState(ch);
        const choices = [_]Choice{
            if (state.read) .{ .label = "Mark unread", .edit = .mark_unread } else .{ .label = "Mark read", .edit = .mark_read },
            .{ .label = "Mark previous read", .edit = .mark_previous },
            if (ch.bookmark) .{ .label = "Remove bookmark", .edit = .unbookmark } else .{ .label = "Bookmark", .edit = .bookmark },
            if (ch.pages.len > 0) .{ .label = "Delete download", .edit = .delete_download } else .{ .label = "Download", .edit = .download },
            .{ .label = "Read online", .edit = .read_online },
        };
        for (choices, 0..) |choice, n| {
            if (manga.local() and (choice.edit == .download or choice.edit == .delete_download or choice.edit == .read_online)) continue;
            if (choice.edit == .read_online and ch.pages.len > 0) continue;
            try app.widgets.button(ui, .{ .choice = n }, .{ .label = choice.label, .on_click = on.bind(.{ .edit = choice.edit }) });
        }
        return;
    }
    // Two to a row, so categories have room below.
    const pairs = [_][2]Choice{
        .{ .{ .label = "Mark all read", .edit = .title_read }, .{ .label = "Mark all unread", .edit = .title_unread } },
        .{ .{ .label = "Chapter options", .edit = .options }, .{ .label = "Remove", .edit = .remove_title } },
    };
    for (pairs, 0..) |pair, n| {
        try ui.open(.{ .pair = n }, .{ .layout = .{ .child_gap = 8 } });
        defer ui.close();
        for (pair, 0..) |choice, m| try app.widgets.button(ui, .{ .choice = n * 2 + m }, .{ .label = choice.label, .on_click = on.bind(.{ .edit = choice.edit }) });
    }
    {
        try ui.open(null, .{ .layout = .{ .child_gap = 8 } });
        defer ui.close();
        try app.widgets.button(ui, "tracking", .{ .label = "Tracking", .on_click = on.bind(.{ .act = @as(lib.Action, .{ .feed = .tracking }) }) });
        try app.widgets.button(ui, "migrate", .{ .label = "Migrate", .on_click = on.bind(.{ .edit = .migrate }) });
    }
    if (model.library.categories.len > 0) try text(ui, "Categories", 14, 0);
    for (model.library.categories) |category| {
        const member = std.mem.indexOfScalar(u32, manga.categories, category.id) != null;
        try app.widgets.button(ui, .{ .category = category.id }, .{ .label = try ui.fmt("{s} {s}", .{ if (member) "[x]" else "[ ]", category.name }), .on_click = on.bind(.{ .edit = @as(Session.Edit, .{ .toggle_category = category.id }) }) });
    }
}

/// Updates, history and the download queue: chapters across titles.
fn feedView(ui: *app.Ui, session: *const Session) !void {
    const model = session.model;
    const artwork = @constCast(session);
    const count = session.feed.len;
    const page_rows = model.pageRows();
    const on = ui.messages(Root);
    if (model.screen == .queue) {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(10), .child_gap = 6, .child_alignment = .center_left } });
        defer ui.close();
        const engine = session.browser.engine;
        const running = if (engine) |e| e.queue.running() else false;
        const waiting = if (engine) |e| e.queue.waitingForWifi() else false;
        try text(ui, if (running) "Queue running" else if (waiting) "Waiting for Wi-Fi" else if (count == 0) "Queue empty" else "Queue paused", 14, 0);
        if (running) try onlineButton(ui, "queue-pause", "Stop", .queue_pause) else if (count > 0) try onlineButton(ui, "queue-start", "Start", .queue_start);
        if (count > 0) try onlineButton(ui, "queue-clear", "Clear", .queue_clear);
    }
    if (model.screen == .queue) {
        const blocked = for (session.feed) |item| {
            if (item.blocked) break true;
        } else false;
        if (blocked) {
            try ui.open("blocked-downloads", .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = .all(8), .child_gap = 3 }, .border = .{ .color = .black, .widths = .outside(1) } });
            try text(ui, "Some chapters cannot be downloaded", 14, 0);
            try ui.text(@import("session.zig").verification_explanation, .{ .font_size = 12, .wrap_mode = .words });
            try ui.text("Tap a blocked title to find another version or source.", .{ .font_size = 12, .wrap_mode = .words });
            ui.close();
        }
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .init(10, 10, 8, 0), .child_gap = 1 } });
        defer ui.close();
        if (count == 0) {
            ui.spacer();
            try text(ui, switch (model.screen) {
                .updates => "No new chapters",
                .history => "Nothing read yet",
                .upcoming => "Nothing expected",
                else => "No downloads queued",
            }, 18, 0);
            try text(ui, switch (model.screen) {
                .updates => "New chapters from your library appear here.",
                .history => "Your reading history will appear here.",
                .upcoming => "Expected releases from your library appear here.",
                else => "Queue chapters from a title to download them.",
            }, 12, 90);
        }
        for (@min(model.offset, count)..@min(model.offset + page_rows, count)) |row| {
            const item = session.feed[row];
            const key = .{ .feed = row };
            try ui.open(key, .{
                .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(40) }, .padding = .init(2, 2, 3, 3), .child_gap = 10, .child_alignment = .center_left },
                .background_color = rowFill(ui, key),
                .on_click = if (model.screen == .queue) (if (item.blocked) on.bind(.{ .online = @as(OnlineCommand, .{ .find_alternative = item.pick.manga }) }) else null) else on.bind(.{ .act = @as(lib.Action, .{ .open_chapter = item.pick }) }),
            });
            {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(23), .height = .fixed(34) }, .child_alignment = .center }, .background_color = .gray(235), .corner_radius = .uniform(2) });
                defer ui.close();
                if (item.pick.manga < model.library.manga.len) if (artwork.coverImage(model.library.manga[item.pick.manga])) |image| ui.content(&image.content);
            }
            {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .child_gap = 3 } });
                defer ui.close();
                try text(ui, item.title, 14, 0);
                try text(ui, item.detail, 10, 90);
            }
            if (model.screen == .history) try text(ui, "Resume", 11, 65);
            ui.close();
        }
        ui.spacer();
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(8), .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try app.widgets.button(ui, "previous-feed", .{ .label = "Previous", .enabled = model.offset > 0, .on_click = on.bind(.{ .act = @as(lib.Action, .{ .list_page = -1 }) }) });
        ui.spacer();
        try ui.print(.{ .font_size = 12 }, "{d}/{d}", .{ if (count == 0) @as(usize, 0) else model.offset / page_rows + 1, (count + page_rows - 1) / page_rows });
        ui.spacer();
        try app.widgets.button(ui, "next-feed", .{ .label = "Next", .enabled = model.offset + page_rows < count, .on_click = on.bind(.{ .act = @as(lib.Action, .{ .list_page = 1 }) }) });
    }
}
/// Convert a completed physical drag to reading-order progress. Comparing
/// logical pointer and element sizes cancels the display's pixel scale.
fn readerDrag(geometry: lib.viewport.Geometry, drag: f.Vec2, size: f.Vec2) f64 {
    return switch (geometry.axis) {
        .page => 0,
        .vertical => if (size.y > 0 and geometry.output.height > geometry.viewport.height)
            -@as(f64, drag.y / size.y) * @as(f64, @floatFromInt(geometry.viewport.height)) / @as(f64, @floatFromInt(geometry.output.height - geometry.viewport.height))
        else
            0,
        .horizontal => if (size.x > 0 and geometry.output.width > geometry.viewport.width)
            -@as(f64, drag.x / size.x) * @as(f64, @floatFromInt(geometry.viewport.width)) / @as(f64, @floatFromInt(geometry.output.width - geometry.viewport.width)) * @as(f64, if (geometry.rtl) -1 else 1)
        else
            0,
    };
}

fn reader(ui: *app.Ui, session: *const Session) !void {
    const model = session.model;
    const ch = model.current() orelse return;
    const on = ui.messages(Root);
    if (session.region_service) |service| {
        const mutable = @constCast(session);
        // Controls overlay the page, so revealing them never resizes or decodes it again.
        const viewport: lib.viewport.Size = .{
            .width = @intFromFloat(@max(1, @round(ui.core.viewport.x * session.display_scale))),
            .height = @intFromFloat(@max(1, @round(ui.core.viewport.y * session.display_scale))),
        };
        if (!std.meta.eql(mutable.region_viewport, viewport)) {
            mutable.clearRegionImage();
            model.reader_presented = false;
            mutable.region_viewport = viewport;
        }
        const request: regions.Request = .{
            .root = session.root,
            .relative = ch.pages[model.page],
            .chapter = ch.id,
            .page = model.page,
            .epoch = session.region_epoch,
            .viewport = viewport,
            .position = model.reader_position,
            .backward = model.reader_pending_end,
            .rtl = model.prefs.rtl,
            .engine = session.browser.engine,
        };
        try ui.task("reader-region", .{ .restart = .{ request.relative, request.chapter, request.page, request.epoch, viewport, @as(u64, @bitCast(request.position)), request.backward, request.rtl } }, regions.render, .{ service, request, on.handler(.region_frame) }, on.handler(.region_frame));
    }
    {
        try ui.open("page", .{ .layout = .{ .sizing = .grow(.{}), .child_alignment = .center }, .background_color = .white, .on_pointer = on.handler(.pointer) });
        defer ui.close();
        if (session.image) |*image| ui.content(@constCast(&image.content)) else try text(ui, if (session.status.len > 0) session.status else if (session.region_service != null) "Loading page…" else if (session.load_image == null) "Page preview" else "Page unavailable", 14, 0);
    }
    if (model.reader_controls) {
        try ui.open("reader-footer", .{ .floating = .{ .mode = .root, .parent_point = .left_bottom, .unit_point = .left_bottom }, .background_color = .white, .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(36) }, .padding = .init(6, 6, 0, 0), .child_gap = 6, .child_alignment = .center_left }, .border = .{ .color = .black, .widths = .{ .top = 1 } } });
        defer ui.close();
        try button(ui, "left-page", if (model.prefs.rtl) "Next" else "Prev", .{ .turn = if (model.prefs.rtl) 1 else -1 });
        ui.spacer();
        if (model.reader_geometry) |geometry| {
            if (geometry.axis != .page) {
                const percent: u8 = @intFromFloat(@round(lib.viewport.clamp(model.reader_position) * 100));
                try ui.print(.{ .font_size = 12 }, "{d}/{d} {d}% {s}", .{ model.page + 1, ch.pages.len, percent, switch (geometry.axis) {
                    .vertical => "down",
                    .horizontal => if (geometry.rtl) "left" else "right",
                    .page => unreachable,
                } });
            } else try ui.print(.{ .font_size = 12 }, "{d} / {d}", .{ model.page + 1, ch.pages.len });
        } else try ui.print(.{ .font_size = 12 }, "{d} / {d}", .{ model.page + 1, ch.pages.len });
        ui.spacer();
        try button(ui, "right-page", if (model.prefs.rtl) "Prev" else "Next", .{ .turn = if (model.prefs.rtl) -1 else 1 });
        if (model.page + 1 == ch.pages.len and model.readerAtEnd() and (session.region_service == null or session.regionCurrent()) and session.next_chapter != null)
            try app.widgets.button(ui, "next-chapter", .{ .label = "Chapter >", .on_click = on.bind(.{ .act = .next_chapter }) });
    }
}
fn onlineButton(ui: *app.Ui, key: anytype, label: []const u8, command: OnlineCommand) !void {
    try app.widgets.button(ui, key, .{ .label = label, .on_click = ui.messages(Root).bind(.{ .online = command }) });
}
fn startTitles(session: *Session) void {
    const b = &session.browser;
    const kind: tachi.Runtime.Browse = if (b.query.len > 0) .{ .search = .{ .query = b.query } } else if (b.latest) .latest else .popular;
    session.start(.{ .browse = .{ .source = b.source_id, .page = b.page, .kind = kind } });
}
fn selectedPreference(session: *Session) ?models.Preference {
    const job = session.browser.preferences orelse return null;
    const i = session.browser.edited_preference orelse return null;
    if (i >= job.result.preferences.len) return null;
    return job.result.preferences[i];
}
fn setPreference(session: *Session, value: std.json.Value) !void {
    const pref = selectedPreference(session) orelse return;
    const key = pref.key orelse return;
    session.start(.{ .set_preference = .{ .source = session.browser.source_id, .key = key, .value = value } });
}
fn onlineUpdate(session: *Session, command: OnlineCommand, ctx: *app.Update(Root)) !void {
    defer session.updateActivity();
    const b = &session.browser;
    const model = session.model;
    const a = model.gpa;
    if (b.busy != null) {
        if (command == .cancel) {
            b.busy.?.cancel();
            session.updateActivity();
        }
        return;
    }
    switch (command) {
        .sources => {
            b.offset = 0;
            try session.act(.help);
            session.start(.sources);
        },
        .extensions => {
            model.screen = .extensions;
            b.offset = 0;
            try b.setQuery(a, "");
            session.start(.{ .extensions = .{} });
        },
        .reload_sources => session.start(.sources),
        .pick_source => |i| {
            const source = b.source_rows[i];
            try b.setSource(a, source);
            if (b.engine) |engine| {
                var arena: std.heap.ArenaAllocator = .init(a);
                defer arena.deinit();
                const browse = (try engine.loadSettings(arena.allocator())).browse;
                b.source_pinned = tachi.views.sourcePinned(source, browse);
                b.source_hidden = !tachi.views.sourceEnabled(source, browse);
                try engine.setLastSource(b.source_id);
            }
            b.latest = false;
            b.page = 1;
            b.offset = 0;
            try b.setQuery(a, "");
            if (b.preferences) |old| old.deinit();
            b.preferences = null;
            if (b.titles) |old| old.deinit();
            b.titles = null;
            model.screen = .catalog;
            startTitles(session);
        },
        .pick_title => |i| try session.addTitle(b.source_id, b.titles.?.result.page.?.mangas[i]),
        .extension => |i| {
            const extension = b.extensions.?.result.extensions[i];
            if (!extension.supported) {
                session.setStatus("This extension API version is not supported");
                return;
            }
            // From the store that listed it, which checks who signed it.
            session.start(.{ .install = .{ .pkg = extension.pkg, .repo = .{ .url = extension.store } } });
            model.screen = .sources;
            b.offset = 0;
        },
        .search => {
            b.page = 1;
            b.offset = 0;
            b.latest = false;
            startTitles(session);
        },
        .latest => {
            b.page = 1;
            b.offset = 0;
            try b.setQuery(a, "");
            b.latest = !b.latest;
            startTitles(session);
        },
        .previous => {
            if (b.offset > 0) b.offset -|= lib.Model.rows else if (model.screen == .catalog and b.page > 1) {
                b.page -= 1;
                startTitles(session);
            }
        },
        .next => {
            if (b.offset + lib.Model.rows < b.count(model.screen)) b.offset += lib.Model.rows else if (model.screen == .catalog and b.titles != null and b.titles.?.result.page.?.hasNextPage) {
                b.page += 1;
                b.offset = 0;
                startTitles(session);
            }
        },
        .source_settings => {
            model.screen = .source_settings;
            b.offset = 0;
            if (b.source_configurable) session.start(.{ .preferences = b.source_id });
        },
        .uninstall => try ctx.confirm(.{ .title = "Remove extension", .text = "Remove this source's extension? Downloaded chapters stay in your library.", .buttons = &.{ "Remove", "Keep" }, .default = 1 }, ctx.handler(.remove_answer)),
        .preference => |i| {
            b.edited_preference = i;
            const pref = selectedPreference(session) orelse return;
            if (!pref.enabled or !pref.visible or pref.key == null) return;
            const current = pref.value orelse pref.defaultValue orelse .null;
            if (std.mem.eql(u8, pref.type, "switch") or std.mem.eql(u8, pref.type, "checkbox")) {
                try setPreference(session, .{ .bool = if (current == .bool) !current.bool else true });
            } else if (pref.entries) |entries| {
                const items = try a.alloc(app.platform.MenuItem, entries.len);
                defer a.free(items);
                for (entries, items, 0..) |entry, *item, index| item.* = .{ .title = entry, .id = index };
                try ctx.menu(.{ .items = items, .at = .init(8, 40) }, ctx.handler(.pref_choice));
            } else if (std.mem.eql(u8, pref.type, "edittext")) {
                try ctx.systemText(.{ .title = pref.title orelse "Source setting", .initial = if (current == .string) current.string else "" }, ctx.handler(.pref_text));
            } else session.setStatus("This source setting has no editable control");
        },
        .refresh_book => session.start(.{ .refresh = model.library.manga[model.manga].id }),
        .update_all => session.start(.{ .update_library = .{} }),
        .scan => session.start(.scan_local),
        .cancel => {},
        .queue_unread => try session.queueUnread(),
        .find_alternative => |index| {
            if (index >= model.library.manga.len) return;
            if (b.migrate_from) |old| model.gpa.free(old);
            b.migrate_from = null;
            session.download_error = false;
            try session.globalSearch(model.library.manga[index].title);
        },
        .toggle_pin, .toggle_hidden => if (b.engine) |engine| {
            if (command == .toggle_pin) {
                b.source_pinned = !b.source_pinned;
                try engine.setSourcePinned(b.source_id, b.source_pinned);
            } else {
                b.source_hidden = !b.source_hidden;
                try engine.setSourceHidden(b.source_id, b.source_hidden);
            }
            try b.refreshSourceRows(a);
        },
        .languages => {
            model.screen = .languages;
            b.offset = 0;
        },
        .stores => {
            model.screen = .stores;
            b.offset = 0;
            try session.loadStores();
        },
        .refresh_stores => session.start(.refresh_stores),
        .remove_store => |i| if (b.engine) |engine| if (i < session.stores.len) {
            try engine.removeStore(session.stores[i].index_url);
            try session.loadStores();
        },
        .toggle_language => |i| if (b.engine) |engine| if (i < b.languages.len) {
            try engine.setLanguage(b.languages[i].code, !b.languages[i].enabled);
            try b.refreshSourceRows(a);
        },
        .show_hidden => {
            b.show_hidden = !b.show_hidden;
            b.offset = 0;
            try b.refreshSourceRows(a);
        },
        .pick_global => |row| if (b.globalHit(row)) |hit| {
            if (b.migrate_from) |from| {
                session.start(.{ .migrate = .{ .from = from, .source = hit.source, .manga = hit.manga } });
                a.free(from);
                b.migrate_from = null;
            } else try session.addTitle(hit.source, hit.manga);
        },
        .queue_start, .queue_pause, .queue_clear => if (b.engine) |engine| {
            switch (command) {
                .queue_start => {
                    try session.connectForDownloads();
                    try engine.queue.start(engine);
                },
                .queue_pause => engine.queue.pause(engine),
                else => try engine.queue.clear(engine),
            }
            try session.refreshFeed();
        },
    }
    ctx.focus("screen");
}
fn browseTabs(ui: *app.Ui, screen: lib.Screen) !void {
    try ui.open("browse-tabs", .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(28) } } });
    defer ui.close();
    inline for (.{ lib.Screen.sources, lib.Screen.extensions }) |tab| {
        const active = screen == tab;
        try ui.open(.{ .browse_tab = tab }, .{
            .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .grow(.{}) }, .child_alignment = .center },
            .background_color = if (active) .gray(245) else .white,
            .border = .{ .color = if (active) .black else .gray(225), .widths = .{ .bottom = if (active) 3 else 1 } },
            .on_click = if (active) null else if (tab == .sources) ui.messages(Root).bind(.{ .online = OnlineCommand.sources }) else ui.messages(Root).bind(.{ .online = OnlineCommand.extensions }),
            .focusable = !active,
        });
        try text(ui, if (tab == .sources) "Sources" else "Extensions", 14, if (active) 0 else 65);
        ui.close();
    }
}

fn browseControl(ui: *app.Ui, key: anytype, label: []const u8, command: OnlineCommand, enabled: bool) !void {
    try ui.open(key, .{
        .layout = .{ .sizing = .{ .height = .fixed(24) }, .padding = .x(6), .child_alignment = .center },
        .background_color = if (enabled and ui.pressed(key)) .gray(218) else .transparent,
        .on_click = if (enabled) ui.messages(Root).bind(.{ .online = command }) else null,
        .focusable = enabled,
    });
    defer ui.close();
    try text(ui, label, 12, if (enabled) 0 else 130);
}

fn sourceInitial(ui: *app.Ui, label: []const u8) !void {
    try ui.open(null, .{
        .layout = .{ .sizing = .fixed(24), .child_alignment = .center },
        .background_color = .gray(235),
        .corner_radius = .uniform(6),
    });
    defer ui.close();
    // Keep the first Unicode scalar intact for translated source names.
    const initial = if (label.len == 0) "?" else label[0..@min(label.len, std.unicode.utf8ByteSequenceLength(label[0]) catch 1)];
    try text(ui, initial, 16, 40);
}

fn browserView(ui: *app.Ui, session: *const Session) !void {
    const b = &session.browser;
    const screen = session.model.screen;
    const root = screen == .sources or screen == .extensions;
    if (root) try browseTabs(ui, screen);
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = if (root) .init(8, 8, 1, 1) else .all(8), .child_gap = if (root) 2 else 5 } });
        defer ui.close();
        switch (screen) {
            .sources => {
                try app.widgets.searchField(ui, "global-query", .{ .text = "", .placeholder = "Search all sources", .sizing = .{ .width = .grow(.{}), .height = .fixed(24) }, .on_change = ui.messages(Root).handler(.global_query) });
                try ui.open(null, .{ .layout = .{ .child_gap = 6 } });
                try browseControl(ui, "reload-sources", "Reload sources", .reload_sources, true);
                try browseControl(ui, "show-hidden", if (b.show_hidden) "Enabled sources" else "All sources", .show_hidden, true);
                try browseControl(ui, "languages", "Languages", .languages, true);
                ui.close();
            },
            .global_search => try text(ui, if (b.migrate_from != null) "Tap the title to move to; its read chapters, categories and notes come along." else "Tap a title to add it and view chapters.", 12, 40),
            .languages => try text(ui, "Sources in checked languages are listed and searched.", 12, 40),
            .extensions => {
                try app.widgets.searchField(ui, "extension-query", .{ .text = b.query, .placeholder = "Filter extensions or language", .sizing = .{ .width = .grow(.{}), .height = .fixed(24) }, .on_change = ui.messages(Root).handler(.online_query) });
                try browseControl(ui, "stores", "Extension stores", .stores, true);
            },
            .catalog => {
                try text(ui, b.source_name, 16, 0);
                try app.widgets.searchField(ui, "source-query", .{ .text = b.query, .placeholder = "Search this source", .on_change = ui.messages(Root).handler(.online_query) });
                try ui.open(null, .{ .layout = .{ .child_gap = 6 } });
                try onlineButton(ui, "source-search", "Search", .search);
                if (b.supports_latest) try onlineButton(ui, "source-latest", if (b.latest) "Popular" else "Latest", .latest);
                try onlineButton(ui, "source-settings", "Source settings", .source_settings);
                ui.close();
                try text(ui, "Tap a title to add it and view chapters.", 12, 40);
            },
            .source_settings => {
                try text(ui, b.source_name, 16, 0);
                try ui.open(null, .{ .layout = .{ .child_gap = 6 } });
                try onlineButton(ui, "pin-source", if (b.source_pinned) "Unpin" else "Pin", .toggle_pin);
                try onlineButton(ui, "hide-source", if (b.source_hidden) "Show" else "Hide", .toggle_hidden);
                try onlineButton(ui, "remove-source", "Remove extension", .uninstall);
                ui.close();
            },
            else => {},
        }
    }
    const count = b.count(screen);
    {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .x(10), .child_gap = 0 } });
        defer ui.close();
        if (count == 0) try text(ui, switch (screen) {
            .sources => "Install an extension to get started.",
            .source_settings => "No source preferences.",
            else => "No results. Try a different search.",
        }, 13, 40);
        for (@min(b.offset, count)..@min(b.offset + lib.Model.rows, count)) |row| {
            const i = if (screen == .extensions) b.extensionIndex(row) else row;
            const label: []const u8 = switch (screen) {
                .sources => b.source_rows[i].name,
                .extensions => b.extensions.?.result.extensions[i].name,
                .catalog => b.titles.?.result.page.?.mangas[i].title,
                .source_settings => b.preferences.?.result.preferences[i].title orelse "Source preference",
                .global_search => b.globalHit(i).?.manga.title,
                .languages => try ui.fmt("{s} {s}", .{ if (b.languages[i].enabled) "[x]" else "[ ]", b.languages[i].code }),
                else => unreachable,
            };
            const command: OnlineCommand = switch (screen) {
                .sources => .{ .pick_source = i },
                .extensions => .{ .extension = i },
                .catalog => .{ .pick_title = i },
                .source_settings => .{ .preference = i },
                .global_search => .{ .pick_global = i },
                .languages => .{ .toggle_language = i },
                else => unreachable,
            };
            const key = .{ .online_row = i };
            try ui.open(key, .{
                .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(33) }, .axis = if (root or screen == .catalog or screen == .global_search) .x else .y, .padding = .init(4, 4, 3, 3), .child_gap = if (root or screen == .catalog or screen == .global_search) 8 else 0, .child_alignment = .center_left },
                .background_color = if (ui.pressed(key)) .gray(218) else .white,
                .on_click = ui.messages(Root).bind(.{ .online = command }),
            });
            if (root) try sourceInitial(ui, label);
            if (screen == .catalog or screen == .global_search) {
                const hit = if (screen == .global_search) b.globalHit(i) else null;
                const remote = if (hit) |value| value.manga else b.titles.?.result.page.?.mangas[i];
                const source = if (hit) |value| value.source else b.source_id;
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .fixed(20), .height = .fixed(30) }, .child_alignment = .center }, .background_color = .gray(238) });
                if (@constCast(session).coverImage(.{ .id = remote.url, .title = remote.title, .source_id = source, .remote = remote })) |image| ui.content(&image.content);
                ui.close();
            }
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y } });
            try text(ui, label, 14, 0);
            switch (screen) {
                .sources => try ui.print(.{ .font_size = 10, .color = .gray(60), .overflow = .ellipsis_end, .wrap_mode = .none }, "{s}  {s}", .{ b.source_rows[i].lang, b.source_notes[i] }),
                .global_search => try text(ui, b.globalHit(i).?.source_name, 10, 60),
                .extensions => {
                    const e = b.extensions.?.result.extensions[i];
                    try ui.print(.{ .font_size = 10, .color = .gray(60), .overflow = .ellipsis_end, .wrap_mode = .none }, "{s}  {s}{s}{s}", .{ e.lang, if (!e.supported) "Unsupported" else if (e.hasUpdate) "Update available" else if (e.installed) "Installed" else "Install", if (e.nsfw) "  [18+]" else "", if (e.jarUrl == null) "  APK" else "" });
                },
                .source_settings => {
                    const p = b.preferences.?.result.preferences[i];
                    const value = p.value orelse p.defaultValue orelse .null;
                    try text(ui, if (value == .bool) if (value.bool) "On" else "Off" else if (value == .string) value.string else p.summary orelse "", 10, 60);
                },
                else => {},
            }
            ui.close();
            ui.close();
        }
        ui.spacer();
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(32) }, .padding = .x(8), .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try browseControl(ui, "online-prev", "Previous", .previous, b.offset > 0 or (screen == .catalog and b.page > 1));
        ui.spacer();
        try ui.print(.{ .font_size = 11 }, "{d} {s}", .{ count, if (count == 1) "result" else "results" });
        ui.spacer();
        const more_source_pages = screen == .catalog and b.titles != null and b.titles.?.result.page.?.hasNextPage;
        try browseControl(ui, "online-next", "Next", .next, b.offset + lib.Model.rows < count or more_source_pages);
    }
}

test "reader drag maps both axes and display scales into reading order" {
    const source: lib.viewport.Size = .{ .width = 1000, .height = 12000 };
    const viewport: lib.viewport.Size = .{ .width = 758, .height = 900 };
    const tall = lib.viewport.Geometry.init(source, viewport, true);
    const a = readerDrag(tall, .init(0, -100), .init(758, 900));
    const b = readerDrag(tall, .init(0, -50), .init(379, 450));
    try std.testing.expect(a > 0);
    try std.testing.expectApproxEqAbs(a, b, 0.000001);
    for ([_]bool{ false, true }) |rtl| {
        const wide = lib.viewport.Geometry.init(.{ .width = 12000, .height = 1000 }, viewport, rtl);
        const delta = readerDrag(wide, .init(-100, 0), .init(758, 900));
        try std.testing.expect(if (rtl) delta < 0 else delta > 0);
    }
    try std.testing.expectEqual(@as(f64, 0), readerDrag(tall, .init(-100, 0), .zero));
}

fn operationTitle(request: @import("tachi").engine.Request) []const u8 {
    return switch (request) {
        .download => "Downloading chapter",
        .read => "Opening chapter",
        .global_search => "Searching sources",
        .browse => "Loading manga",
        .sources => "Loading sources",
        .extensions, .refresh_stores => "Loading extensions",
        .install => "Installing extension",
        .uninstall => "Removing extension",
        .update_library => "Checking for new chapters",
        .scan_local => "Scanning local manga",
        .export_backup => "Creating backup",
        .import_backup => "Restoring backup",
        .export_downloads => "Exporting downloads",
        .import_downloads => "Importing downloads",
        .preferences, .set_preference => "Loading source settings",
        .migrate => "Migrating manga",
        else => "Updating manga",
    };
}
