const std = @import("std");
const f = @import("fabrum");
const app = f.app;
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @This();
const tachi = @import("tachi");
const models = tachi.models;
pub const OnlineCommand = union(enum) { toggle_pin, toggle_hidden, show_hidden, extensions, reload_sources, pick_source: usize, pick_title: usize, extension: usize, next, previous, search, latest, source_settings, preference: usize, uninstall, refresh_book, update_all, scan, cancel, queue_unread, queue_start, queue_pause, queue_clear, pick_global: usize };
pub const BackupCommand = enum { create, export_downloads, import_downloads };
pub const State = struct { focused: bool = false, tapping: bool = false, reader_updates: u8 = 0 };
pub const Props = struct {};
pub const Msg = union(enum) { act: lib.Action, global_query: []const u8, edit: Session.Edit, setting: lib.Setting, category_edit: Session.CategoryEdit, new_category: []const u8, restore: usize, backup_command: BackupCommand, key: app.KeyEvent, pointer: app.Pointer, query: []const u8, online_query: []const u8, online: OnlineCommand, poll, pref_text: ?[]const u8, pref_choice: ?usize, remove_answer: ?usize, focus, quit };

pub fn update(state: *State, msg: Msg, ctx: *app.Update(Root)) !void {
    const session = @constCast(ctx.use(Session));
    switch (msg) {
        .poll => {
            try session.poll();
            if (session.browser.busy == null) ctx.focus("screen");
        },
        .online => |command| try onlineUpdate(session, command, ctx),
        .global_query => |query| if (session.browser.busy == null and std.mem.trim(u8, query, " ").len > 0) {
            if (session.browser.migrate_from) |id| session.model.gpa.free(id);
            session.browser.migrate_from = null;
            try session.globalSearch(query);
        },
        .category_edit => |change| if (session.browser.busy == null) {
            session.editCategory(change) catch |err| {
                session.status = try std.fmt.allocPrint(session.model.gpa, "Category not changed: {s}", .{@errorName(err)});
            };
        },
        .new_category => |name| if (session.browser.busy == null) {
            session.addCategory(name) catch |err| {
                session.status = try std.fmt.allocPrint(session.model.gpa, "Category not added: {s}", .{@errorName(err)});
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
                session.status = try std.fmt.allocPrint(session.model.gpa, "Setting not saved: {s}", .{@errorName(err)});
            };
            ctx.focus("screen");
        },
        .edit => |choice| if (session.browser.busy == null) {
            session.edit(choice) catch |err| {
                session.status = try std.fmt.allocPrint(session.model.gpa, "Not changed: {s}", .{@errorName(err)});
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
            if (action == .help) {
                session.browser.offset = 0;
                try session.act(action);
                session.start(.sources);
                return;
            }
            const effective: lib.Action = if (action == .next_chapter) .{ .read = session.next_chapter orelse return } else action;
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
                .press => state.tapping = true,
                .drag, .cancel, .long_press => state.tapping = false,
                .release => {
                    if (!state.tapping) return;
                    state.tapping = false;
                    if (event.local.x < 0 or event.local.y < 0 or event.local.x > event.size.x or event.local.y > event.size.y) return;
                    const left = event.local.x < event.size.x / 2;
                    const forward = left == session.model.prefs.rtl;
                    try session.act(.{ .turn = if (forward) 1 else -1 });
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
                .escape => if (model.screen == .library) {
                    try ctx.quit();
                    return;
                } else .back,
                .page_down, .right => if (model.screen == .reader) .{ .turn = 1 } else .{ .list_page = 1 },
                .page_up, .left => if (model.screen == .reader) .{ .turn = -1 } else .{ .list_page = -1 },
                .f => |n| if (n == 10) .settings else return,
                else => return,
            };
            try session.act(action);
            if (model.screen == .reader) refreshReader(state, session, ctx);
        },
    }
}
// Panel policy leaves cleaning refreshes to reading, never to row press/release.
fn refreshReader(state: *State, session: *const Session, ctx: *app.Update(Root)) void {
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
    return .gray(246);
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
pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
    const session = ui.use(Session);
    const model = session.model;
    const on = ui.messages(Root);
    if (session.browser.busy != null) try ui.every("network-poll", .fromMilliseconds(200), on.bind(.poll)) else if (model.screen == .queue) try ui.every("queue-poll", .fromMilliseconds(2000), on.bind(.poll));
    if (!state.focused) try ui.after("initial-focus", .fromMilliseconds(0), on.bind(.focus));
    try ui.open("screen", .{
        .layout = .{ .sizing = .grow(.{}), .axis = .y },
        .background_color = .white,
        .focus = .{ .on_key = on.handler(.key), .keys = .{ .typing = false, .escape = true } },
    });
    defer ui.close();
    // A compact toolbar, with 36-point touch targets on the Verse.
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(8), .child_gap = 6, .child_alignment = .center_left }, .border = .{ .color = .black, .widths = .{ .bottom = 1 } } });
        defer ui.close();
        if (model.screen != .library and session.browser.busy == null) try button(ui, "back", "Back", .back);
        try text(ui, switch (model.screen) {
            .library => "PocketManga",
            .chapters => "Chapters",
            .reader => "Reader",
            .settings => "Settings",
            .sources => "Sources",
            .extensions => "Extensions",
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
        }, 19, 0);
        ui.spacer();
        if (model.screen == .library and session.browser.busy == null) try button(ui, "browse", "Browse", .help);
        if (model.screen != .settings and session.browser.busy == null) try button(ui, "settings", "Aa", .settings);
    }
    if (session.download_error and session.browser.busy == null) {
        try ui.open("download-error", .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = .all(10), .child_gap = 5 }, .border = .{ .color = .black, .widths = .outside(2) } });
        try text(ui, if (session.download_canceled) "Download canceled - tap chapter to resume" else "Download failed - tap chapter to resume", 15, 0);
        if (session.download_identity) |identity| try text(ui, identity.chapter, 14, 0);
        try text(ui, session.status, 13, 0);
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
        .settings => {
            try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 16 } });
            defer ui.close();
            try text(ui, "Reading direction", 15, 0);
            try button(ui, "direction", if (model.prefs.rtl) "Right to left (manga)" else "Left to right", .rtl);
            try text(ui, "Page refresh", 15, 0);
            try button(ui, "refresh", if (model.prefs.full_refresh) "Full refresh on each page" else "Partial (periodic cleaning)", .refresh);
            try text(ui, "Physical Next always advances a page.", 12, 60);
            try text(ui, "Direction changes the left / right tap zones.", 12, 60);
            try onlineButton(ui, "scan-local", "Scan local manga", .scan);
            try button(ui, "engine-settings", "Library settings", .{ .feed = .engine_settings });
            try button(ui, "categories", "Categories", .{ .feed = .categories });
            try button(ui, "backup", "Backup and restore", .{ .feed = .backup });
            ui.spacer();
            try app.widgets.button(ui, "quit", .{ .label = "Close PocketManga", .on_click = on.bind(.quit) });
        },
        .sources, .extensions, .catalog, .source_settings, .global_search => try browserView(ui, session),
        .updates, .history, .queue => try feedView(ui, session),
        .chapter_menu, .title_menu => try menuView(ui, model),
        .engine_settings => try settingsView(ui, session),
        .backup => try backupView(ui, session),
        .categories => try categoriesView(ui, model),
    }
    if (session.status.len > 0 and !session.download_error and session.browser.busy == null) try text(ui, session.status, 11, 0);
}
fn list(ui: *app.Ui, model: *const lib.Model) !void {
    const is_library = model.screen == .library;
    const count = if (is_library) model.titleCount() else model.chapterCount();
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = .all(10), .child_gap = 4 } });
        defer ui.close();
        if (is_library) {
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 6, .child_alignment = .center_left } });
            defer ui.close();
            if (model.library.manga.len > 0) try onlineButton(ui, "update-library", "Update", .update_all);
            try button(ui, "updates", "Updates", .{ .feed = .updates });
            try button(ui, "history", "History", .{ .feed = .history });
            try button(ui, "queue", "Downloads", .{ .feed = .queue });
        }
        if (is_library) try app.widgets.searchField(ui, "query", .{ .text = model.query_text, .placeholder = "Search title or author", .on_change = ui.messages(Root).handler(.query) });
        if (is_library and model.categories.len > 1) {
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 8, .child_alignment = .center_left } });
            defer ui.close();
            try app.widgets.button(ui, "previous-category", .{ .label = "<", .enabled = model.category > 0, .on_click = ui.messages(Root).bind(.{ .act = @as(lib.Action, .{ .category = -1 }) }) });
            ui.spacer();
            try text(ui, model.categories[model.category], 14, 0);
            ui.spacer();
            try app.widgets.button(ui, "next-category", .{ .label = ">", .enabled = model.category + 1 < model.categories.len, .on_click = ui.messages(Root).bind(.{ .act = @as(lib.Action, .{ .category = 1 }) }) });
        }
        if (!is_library) {
            try text(ui, model.library.manga[model.manga].title, 17, 0);
            if (model.library.manga[model.manga].source_id != null) {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 6, .child_alignment = .center_left } });
                defer ui.close();
                try onlineButton(ui, "refresh-chapters", "Refresh chapters", .refresh_book);
                try onlineButton(ui, "queue-unread", "Queue unread", .queue_unread);
            }
        }
        try ui.print(.{ .font_size = 12, .color = .gray(60) }, "{d} {s}  /  Library", .{ count, if (is_library) (if (count == 1) "title" else "titles") else (if (count == 1) "chapter" else "chapters") });
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .x(10), .child_gap = 4 } });
        defer ui.close();
        if (count == 0) {
            try text(ui, if (model.query_text.len > 0) "No matching titles" else "Your next story starts here", 18, 0);
            try text(ui, "Tap Browse to install sources and add manga.", 12, 60);
            try text(ui, "Local folders can be scanned in Settings.", 12, 60);
        }
        for (@min(model.offset, count)..@min(model.offset + lib.Model.rows, count)) |row| {
            const i = if (is_library) model.titleIndex(row) else model.chapterIndex(row);
            const title = if (is_library) model.library.manga[i].title else model.library.manga[model.manga].chapters[i].title;
            const on = ui.messages(Root);
            const key = .{ .row = i };
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_alignment = .center_left }, .border = .{ .color = .gray(130), .widths = .{ .bottom = 1 } } });
            defer {
                app.widgets.button(ui, .{ .menu = i }, .{ .label = "...", .on_click = on.bind(.{ .act = @as(lib.Action, .{ .menu = i }) }) }) catch {};
                ui.close();
            }
            try ui.open(key, .{
                .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(37) }, .axis = .y, .padding = .init(8, 8, 3, 3), .child_gap = 1 },
                .background_color = rowFill(ui, key),
                .on_click = on.bind(.{ .act = if (is_library) @as(lib.Action, .{ .open = i }) else @as(lib.Action, .{ .read = i }) }),
            });
            try text(ui, title, 14, 0);
            if (is_library) {
                try ui.print(.{ .font_size = 10, .color = .gray(60) }, "{d} chapters  {s}", .{ model.library.manga[i].chapters.len, model.library.manga[i].author });
            } else {
                const ch = model.library.manga[model.manga].chapters[i];
                if (ch.pages.len == 0) try text(ui, "Tap to download and read", 10, 60) else try ui.print(.{ .font_size = 10, .color = .gray(60) }, "{d} pages  /  {s}", .{ ch.pages.len, if (model.readState(ch).read) "Read" else if (model.readState(ch).started) "Reading" else "Unread" });
            }
            ui.close();
        }
        ui.spacer();
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(8), .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try app.widgets.button(ui, "previous-list", .{ .label = "Previous", .enabled = model.offset > 0, .on_click = ui.messages(Root).bind(.{ .act = @as(lib.Action, .{ .list_page = -1 }) }) });
        ui.spacer();
        try ui.print(.{ .font_size = 12 }, "{d}/{d}", .{ if (count == 0) @as(usize, 0) else model.offset / lib.Model.rows + 1, (count + lib.Model.rows - 1) / lib.Model.rows });
        ui.spacer();
        try app.widgets.button(ui, "next-list", .{ .label = "Next", .enabled = model.offset + lib.Model.rows < count, .on_click = ui.messages(Root).bind(.{ .act = @as(lib.Action, .{ .list_page = 1 }) }) });
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
    var sorted: [64]tachi.library.Category = undefined;
    const count = @min(model.library.categories.len, sorted.len);
    @memcpy(sorted[0..count], model.library.categories[0..count]);
    std.mem.sort(tachi.library.Category, sorted[0..count], {}, struct {
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
        };
        for (choices, 0..) |choice, n| {
            if (manga.local() and (choice.edit == .download or choice.edit == .delete_download)) continue;
            try app.widgets.button(ui, .{ .choice = n }, .{ .label = choice.label, .on_click = on.bind(.{ .edit = choice.edit }) });
        }
        return;
    }
    for ([_]Choice{
        .{ .label = "Mark all read", .edit = .title_read },
        .{ .label = "Mark all unread", .edit = .title_unread },
        .{ .label = "Remove from library", .edit = .remove_title },
        .{ .label = "Migrate to another source", .edit = .migrate },
    }, 0..) |choice, n| try app.widgets.button(ui, .{ .choice = n }, .{ .label = choice.label, .on_click = on.bind(.{ .edit = choice.edit }) });
    if (model.library.categories.len > 0) try text(ui, "Categories", 14, 0);
    for (model.library.categories) |category| {
        const member = std.mem.indexOfScalar(u32, manga.categories, category.id) != null;
        try app.widgets.button(ui, .{ .category = category.id }, .{ .label = try ui.fmt("{s} {s}", .{ if (member) "[x]" else "[ ]", category.name }), .on_click = on.bind(.{ .edit = @as(Session.Edit, .{ .toggle_category = category.id }) }) });
    }
}

/// Updates, history and the download queue: chapters across titles.
fn feedView(ui: *app.Ui, session: *const Session) !void {
    const model = session.model;
    const count = session.feed.len;
    const on = ui.messages(Root);
    if (model.screen == .queue) {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(10), .child_gap = 6, .child_alignment = .center_left } });
        defer ui.close();
        try onlineButton(ui, "queue-start", "Start", .queue_start);
        try onlineButton(ui, "queue-pause", "Pause", .queue_pause);
        try onlineButton(ui, "queue-clear", "Clear", .queue_clear);
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .x(10), .child_gap = 4 } });
        defer ui.close();
        if (count == 0) try text(ui, switch (model.screen) {
            .updates => "No new chapters",
            .history => "Nothing read yet",
            else => "No downloads queued",
        }, 16, 0);
        for (@min(model.offset, count)..@min(model.offset + lib.Model.rows, count)) |row| {
            const item = session.feed[row];
            const key = .{ .feed = row };
            try ui.open(key, .{
                .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(37) }, .axis = .y, .padding = .init(8, 8, 3, 3), .child_gap = 1 },
                .background_color = rowFill(ui, key),
                .border = .{ .color = .gray(130), .widths = .{ .bottom = 1 } },
                .on_click = if (model.screen == .queue) null else on.bind(.{ .act = @as(lib.Action, .{ .open_chapter = item.pick }) }),
            });
            try text(ui, item.title, 14, 0);
            try text(ui, item.detail, 10, 60);
            ui.close();
        }
        ui.spacer();
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(8), .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try app.widgets.button(ui, "previous-feed", .{ .label = "Previous", .enabled = model.offset > 0, .on_click = on.bind(.{ .act = @as(lib.Action, .{ .list_page = -1 }) }) });
        ui.spacer();
        try ui.print(.{ .font_size = 12 }, "{d}/{d}", .{ if (count == 0) @as(usize, 0) else model.offset / lib.Model.rows + 1, (count + lib.Model.rows - 1) / lib.Model.rows });
        ui.spacer();
        try app.widgets.button(ui, "next-feed", .{ .label = "Next", .enabled = model.offset + lib.Model.rows < count, .on_click = on.bind(.{ .act = @as(lib.Action, .{ .list_page = 1 }) }) });
    }
}
fn reader(ui: *app.Ui, session: *const Session) !void {
    const model = session.model;
    const ch = model.current() orelse return;
    const on = ui.messages(Root);
    {
        try ui.open("page", .{ .layout = .{ .sizing = .grow(.{}), .child_alignment = .center }, .background_color = .white, .on_pointer = on.handler(.pointer) });
        defer ui.close();
        if (session.image) |*image| ui.content(@constCast(&image.content)) else try text(ui, if (session.load_image == null) "Page preview" else "Page unavailable", 14, 0);
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(6), .child_gap = 6, .child_alignment = .center_left }, .border = .{ .color = .black, .widths = .{ .top = 1 } } });
        defer ui.close();
        try button(ui, "left-page", if (model.prefs.rtl) "Next" else "Prev", .{ .turn = if (model.prefs.rtl) 1 else -1 });
        ui.spacer();
        try ui.print(.{ .font_size = 12 }, "{d} / {d}", .{ model.page + 1, ch.pages.len });
        ui.spacer();
        try button(ui, "right-page", if (model.prefs.rtl) "Prev" else "Next", .{ .turn = if (model.prefs.rtl) -1 else 1 });
        if (model.page + 1 == ch.pages.len and session.next_chapter != null)
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
        .pick_title => |i| {
            const manga = b.titles.?.result.page.?.mangas[i];
            session.start(.{ .add = .{ .source = b.source_id, .manga = manga } });
        },
        .extension => |i| {
            const extension = b.extensions.?.result.extensions[i];
            if (!extension.supported) {
                session.status = "This extension API version is not supported";
                return;
            }
            session.start(.{ .install = .{ .pkg = extension.pkg } });
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
            } else session.status = "This source setting has no editable control";
        },
        .refresh_book => session.start(.{ .refresh = model.library.manga[model.manga].id }),
        .update_all => session.start(.{ .update_library = .{} }),
        .scan => session.start(.scan_local),
        .cancel => {},
        .queue_unread => try session.queueUnread(),
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
            } else session.start(.{ .add = .{ .source = hit.source, .manga = hit.manga } });
        },
        .queue_start, .queue_pause, .queue_clear => if (b.engine) |engine| {
            switch (command) {
                .queue_start => try engine.queue.start(engine),
                .queue_pause => engine.queue.pause(engine),
                else => try engine.queue.clear(engine),
            }
            try session.refreshFeed();
        },
    }
    ctx.focus("screen");
}
fn browserView(ui: *app.Ui, session: *const Session) !void {
    const b = &session.browser;
    const screen = session.model.screen;
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = .all(8), .child_gap = 5 } });
        defer ui.close();
        switch (screen) {
            .sources => {
                try app.widgets.searchField(ui, "global-query", .{ .text = "", .placeholder = "Search all sources", .on_change = ui.messages(Root).handler(.global_query) });
                try onlineButton(ui, "extensions", "Install / update extensions", .extensions);
                try ui.open(null, .{ .layout = .{ .child_gap = 6 } });
                try onlineButton(ui, "reload-sources", "Reload sources", .reload_sources);
                try onlineButton(ui, "show-hidden", if (b.show_hidden) "Enabled sources" else "All sources", .show_hidden);
                ui.close();
            },
            .global_search => try text(ui, if (b.migrate_from != null) "Tap the title to move to; its read chapters, categories and notes come along." else "Tap a title to add it and view chapters.", 12, 40),
            .extensions => {
                try app.widgets.searchField(ui, "extension-query", .{ .text = b.query, .placeholder = "Filter extensions or language", .on_change = ui.messages(Root).handler(.online_query) });
                try text(ui, "Tap an extension to install or update it.", 12, 40);
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
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .x(10), .child_gap = 4 } });
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
                else => unreachable,
            };
            const command: OnlineCommand = switch (screen) {
                .sources => .{ .pick_source = i },
                .extensions => .{ .extension = i },
                .catalog => .{ .pick_title = i },
                .source_settings => .{ .preference = i },
                .global_search => .{ .pick_global = i },
                else => unreachable,
            };
            const key = .{ .online_row = i };
            try ui.open(key, .{
                .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(33) }, .axis = .y, .padding = .init(8, 8, 3, 3) },
                .background_color = rowFill(ui, key),
                .border = .{ .color = .gray(140), .widths = .{ .bottom = 1 } },
                .on_click = ui.messages(Root).bind(.{ .online = command }),
            });
            try text(ui, label, 14, 0);
            switch (screen) {
                .sources => try text(ui, b.source_rows[i].lang, 10, 60),
                .global_search => try text(ui, b.globalHit(i).?.source_name, 10, 60),
                .extensions => {
                    const e = b.extensions.?.result.extensions[i];
                    try ui.print(.{ .font_size = 10, .color = .gray(60) }, "{s}  {s}{s}{s}", .{ e.lang, if (!e.supported) "Unsupported" else if (e.hasUpdate) "Update available" else if (e.installed) "Installed" else "Install", if (e.nsfw) "  [18+]" else "", if (e.jarUrl == null) "  APK" else "" });
                },
                .source_settings => {
                    const p = b.preferences.?.result.preferences[i];
                    const value = p.value orelse p.defaultValue orelse .null;
                    try text(ui, if (value == .bool) if (value.bool) "On" else "Off" else if (value == .string) value.string else p.summary orelse "", 10, 60);
                },
                else => {},
            }
            ui.close();
        }
        ui.spacer();
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(8), .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try app.widgets.button(ui, "online-prev", .{ .label = "Previous", .enabled = b.offset > 0 or (screen == .catalog and b.page > 1), .on_click = ui.messages(Root).bind(.{ .online = OnlineCommand.previous }) });
        ui.spacer();
        try ui.print(.{ .font_size = 11 }, "{d} {s}", .{ count, if (count == 1) "result" else "results" });
        ui.spacer();
        const more_source_pages = screen == .catalog and b.titles != null and b.titles.?.result.page.?.hasNextPage;
        try app.widgets.button(ui, "online-next", .{ .label = "Next", .enabled = b.offset + lib.Model.rows < count or more_source_pages, .on_click = ui.messages(Root).bind(.{ .online = OnlineCommand.next }) });
    }
}
