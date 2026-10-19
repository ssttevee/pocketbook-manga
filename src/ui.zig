const std = @import("std");
const f = @import("fabrum");
const app = f.app;
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @This();
const online = @import("online.zig");
const models = @import("source_models.zig");
pub const OnlineCommand = union(enum) { extensions, reload_sources, pick_source: usize, pick_title: usize, extension: usize, next, previous, search, latest, source_settings, preference: usize, uninstall, refresh_book, update_all, scan, cancel };
pub const State = struct { focused: bool = false, tapping: bool = false };
pub const Props = struct {};
pub const Msg = union(enum) { act: lib.Action, key: app.KeyEvent, pointer: app.Pointer, query: []const u8, online_query: []const u8, online: OnlineCommand, poll, pref_text: ?[]const u8, pref_choice: ?usize, remove_answer: ?usize, focus, quit };

pub fn update(state: *State, msg: Msg, ctx: *app.Update(Root)) !void {
    const session = @constCast(ctx.use(Session));
    switch (msg) {
        .poll => {
            try session.poll();
            if (session.browser.busy == null) ctx.focus("screen");
        },
        .online => |command| try onlineUpdate(session, command, ctx),
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
            if (action == .read or action == .next_chapter) {
                const book = session.model.library.manga[session.model.manga];
                const index = if (action == .read) action.read else session.model.chapter + 1;
                if (index < book.chapters.len) {
                    const chapter = book.chapters[index];
                    if (chapter.pages.len == 0 and chapter.remote != null) {
                        if (session.browser.pending_chapter) |id| session.model.gpa.free(id);
                        session.browser.pending_chapter = try session.model.gpa.dupe(u8, chapter.id);
                        session.start(.{ .download = .{ .book = book, .chapter = chapter } });
                        return;
                    }
                }
            }
            if (action == .back) session.browser.offset = 0;
            try session.act(action);
            if (session.model.screen == .reader and session.model.prefs.full_refresh) ctx.refresh(.page);
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
                    if (session.model.prefs.full_refresh) ctx.refresh(.page);
                    ctx.focus("screen");
                },
            }
        },
        .key => |event| {
            if (event.phase != .press and event.phase != .repeat) return;
            const model = session.model;
            if (session.browser.busy != null) {
                if (event.key == .escape) session.browser.busy.?.cancel();
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
            if (model.screen == .reader and model.prefs.full_refresh) ctx.refresh(.page);
        },
    }
}
fn text(ui: *app.Ui, value: []const u8, size: f32, gray: u8) !void {
    try ui.text(value, .{ .font_size = size, .color = .gray(gray), .overflow = .ellipsis_end, .wrap_mode = .none });
}
fn button(ui: *app.Ui, key: anytype, label: []const u8, action: lib.Action) !void {
    try app.widgets.button(ui, key, .{ .label = label, .on_click = ui.messages(Root).bind(.{ .act = action }) });
}
pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
    const session = ui.use(Session);
    const model = session.model;
    const on = ui.messages(Root);
    if (session.browser.busy != null) try ui.every("network-poll", .fromMilliseconds(200), on.bind(.poll));
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
        }, 19, 0);
        ui.spacer();
        if (model.screen == .library and session.browser.busy == null) try button(ui, "browse", "Browse", .help);
        if (model.screen != .settings and session.browser.busy == null) try button(ui, "settings", "Aa", .settings);
    }
    if (session.download_error and session.browser.busy == null) {
        try ui.open("download-error", .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = .all(10), .child_gap = 5 }, .border = .{ .color = .black, .widths = .all(2) } });
        try text(ui, if (std.mem.startsWith(u8, session.status, "Download canceled")) "Download canceled - tap chapter to resume" else "Download failed - tap chapter to resume", 15, 0);
        try ui.text(session.status[0..@min(session.status.len, 240)], .{ .font_size = 13, .wrap_mode = .words });
        ui.close();
    }
    if (session.browser.busy) |job| {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 16 } });
        defer ui.close();
        try text(ui, "Working on your reader", 18, 0);
        try text(ui, switch (job.request) {
            .sources => "Loading extensions...",
            .extensions => "Loading extension repository...",
            .install => "Downloading and installing extension...",
            .uninstall => "Removing extension...",
            .titles => "Loading titles...",
            .download => "Downloading chapter...",
            .scan => "Scanning local manga...",
            .preferences, .set_preference => "Loading source settings...",
            else => "Updating chapter lists...",
        }, 13, 40);
        const total = job.pages_total.load(.acquire);
        if (total > 0) try ui.print(.{ .font_size = 14 }, "{d} / {d} pages", .{ job.pages_done.load(.acquire), total });
        try onlineButton(ui, "cancel-job", "Cancel", .cancel);
        try text(ui, "Java startup can take a while on the Verse.", 12, 40);
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
            ui.spacer();
            try app.widgets.button(ui, "quit", .{ .label = "Close PocketManga", .on_click = on.bind(.quit) });
        },
        .sources, .extensions, .catalog, .source_settings => try browserView(ui, session),
    }
    if (session.status.len > 0 and !session.download_error) try text(ui, session.status, 11, 0);
}
fn list(ui: *app.Ui, model: *const lib.Model) !void {
    const is_library = model.screen == .library;
    const count = if (is_library) model.titleCount() else model.library.manga[model.manga].chapters.len;
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = .all(10), .child_gap = 4 } });
        defer ui.close();
        if (is_library and model.library.manga.len > 0) try onlineButton(ui, "update-library", "Update library", .update_all);
        if (is_library) try app.widgets.searchField(ui, "query", .{ .text = model.query_text, .placeholder = "Search title or author", .on_change = ui.messages(Root).handler(.query) });
        if (!is_library) {
            try text(ui, model.library.manga[model.manga].title, 17, 0);
            if (model.library.manga[model.manga].source_id != null) try onlineButton(ui, "refresh-chapters", "Refresh chapters", .refresh_book);
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
            const i = if (is_library) model.titleIndex(row) else row;
            const title = if (is_library) model.library.manga[i].title else model.library.manga[model.manga].chapters[i].title;
            const on = ui.messages(Root);
            try ui.open(.{ .row = i }, .{
                .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(37) }, .axis = .y, .padding = .init(8, 8, 3, 3), .child_gap = 1 },
                .background_color = .gray(246),
                .border = .{ .color = .gray(130), .widths = .{ .bottom = 1 } },
                .on_click = on.bind(.{ .act = if (is_library) @as(lib.Action, .{ .open = i }) else @as(lib.Action, .{ .read = i }) }),
            });
            try text(ui, title, 14, 0);
            if (is_library) {
                try ui.print(.{ .font_size = 10, .color = .gray(60) }, "{d} chapters  {s}", .{ model.library.manga[i].chapters.len, model.library.manga[i].author });
            } else {
                const ch = model.library.manga[model.manga].chapters[i];
                const p = model.progress(ch.id);
                if (ch.pages.len == 0) try text(ui, "Tap to download and read", 10, 60) else try ui.print(.{ .font_size = 10, .color = .gray(60) }, "{d} pages  /  {s}", .{ ch.pages.len, if (p) |v| if (v.completed) "Read" else "Reading" else "Unread" });
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
        if (model.page + 1 == ch.pages.len and model.chapter + 1 < model.library.manga[model.manga].chapters.len)
            try app.widgets.button(ui, "next-chapter", .{ .label = "Chapter >", .on_click = on.bind(.{ .act = .next_chapter }) });
    }
}
fn onlineButton(ui: *app.Ui, key: anytype, label: []const u8, command: OnlineCommand) !void {
    try app.widgets.button(ui, key, .{ .label = label, .on_click = ui.messages(Root).bind(.{ .online = command }) });
}
fn startTitles(session: *Session) void {
    session.start(.{ .titles = .{ .source = session.browser.source_id, .query = session.browser.query, .page = session.browser.page, .latest = session.browser.latest } });
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
        if (command == .cancel) b.busy.?.cancel();
        return;
    }
    switch (command) {
        .extensions => {
            model.screen = .extensions;
            b.offset = 0;
            try b.setQuery(a, "");
            session.start(.extensions);
        },
        .reload_sources => session.start(.sources),
        .pick_source => |i| {
            const source = b.sources.?.result.sources[i];
            b.source_id = try source.idInt();
            if (b.source_name.len > 0) a.free(b.source_name);
            if (b.extension_pkg.len > 0) a.free(b.extension_pkg);
            b.source_name = try a.dupe(u8, source.name);
            b.extension_pkg = try a.dupe(u8, source.extensionPkg);
            b.source_configurable = source.isConfigurable;
            b.supports_latest = source.supportsLatest;
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
            const manga = b.titles.?.result.titles.?.mangas[i];
            session.start(.{ .add = .{ .source = b.source_id, .manga = manga } });
        },
        .extension => |i| {
            const extension = b.extensions.?.result.extensions[i];
            if (!extension.supported) {
                session.status = "This extension API version is not supported";
                return;
            }
            session.start(.{ .install = extension.pkg });
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
            if (b.offset + lib.Model.rows < b.count(model.screen)) b.offset += lib.Model.rows else if (model.screen == .catalog and b.titles != null and b.titles.?.result.titles.?.hasNextPage) {
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
        .refresh_book => session.start(.{ .refresh = model.library.manga[model.manga] }),
        .update_all => session.start(.update_all),
        .scan => session.start(.scan),
        .cancel => {},
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
                try onlineButton(ui, "extensions", "Install / update extensions", .extensions);
                try onlineButton(ui, "reload-sources", "Reload installed sources", .reload_sources);
            },
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
                try onlineButton(ui, "remove-source", "Remove extension", .uninstall);
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
                .sources => b.sources.?.result.sources[i].name,
                .extensions => b.extensions.?.result.extensions[i].name,
                .catalog => b.titles.?.result.titles.?.mangas[i].title,
                .source_settings => b.preferences.?.result.preferences[i].title orelse "Source preference",
                else => unreachable,
            };
            const command: OnlineCommand = switch (screen) {
                .sources => .{ .pick_source = i },
                .extensions => .{ .extension = i },
                .catalog => .{ .pick_title = i },
                .source_settings => .{ .preference = i },
                else => unreachable,
            };
            try ui.open(.{ .online_row = i }, .{
                .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(33) }, .axis = .y, .padding = .init(8, 8, 3, 3) },
                .background_color = .gray(246),
                .border = .{ .color = .gray(140), .widths = .{ .bottom = 1 } },
                .on_click = ui.messages(Root).bind(.{ .online = command }),
            });
            try text(ui, label, 14, 0);
            switch (screen) {
                .sources => try text(ui, b.sources.?.result.sources[i].lang, 10, 60),
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
        const more_source_pages = screen == .catalog and b.titles != null and b.titles.?.result.titles.?.hasNextPage;
        try app.widgets.button(ui, "online-next", .{ .label = "Next", .enabled = b.offset + lib.Model.rows < count or more_source_pages, .on_click = ui.messages(Root).bind(.{ .online = OnlineCommand.next }) });
    }
}
