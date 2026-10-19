const std = @import("std");
const f = @import("fabrum");
const app = f.app;
const lib = @import("library.zig");
const Session = @import("session.zig").Session;
const Root = @This();
pub const State = struct { focused: bool = false, tapping: bool = false };
pub const Props = struct {};
pub const Msg = union(enum) { act: lib.Action, key: app.KeyEvent, pointer: app.Pointer, query: []const u8, focus, quit };

pub fn update(state: *State, msg: Msg, ctx: *app.Update(Root)) !void {
    const session = @constCast(ctx.use(Session));
    switch (msg) {
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
        if (model.screen != .library) try button(ui, "back", "Back", .back);
        try text(ui, switch (model.screen) {
            .library => "PocketManga",
            .chapters => "Chapters",
            .reader => "Reader",
            .settings => "Settings",
            .help => "Browse & sync",
        }, 19, 0);
        ui.spacer();
        if (model.screen == .library) try button(ui, "browse", "Browse", .help);
        if (model.screen != .settings) try button(ui, "settings", "Aa", .settings);
    }
    switch (model.screen) {
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
            ui.spacer();
            try app.widgets.button(ui, "quit", .{ .label = "Close PocketManga", .on_click = on.bind(.quit) });
        },
        .help => {
            try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 14 } });
            defer ui.close();
            try text(ui, "Your extensions, on your computer", 16, 0);
            try text(ui, "Use pocketmanga-sync to install sources,", 12, 40);
            try text(ui, "search titles and download chapters.", 12, 40);
            try text(ui, "Copy the library folder to the reader:", 12, 40);
            try text(ui, "/applications/pocketmanga/", 12, 0);
            try text(ui, "Local manga works without any extensions.", 12, 40);
            try text(ui, "See README.md for commands and setup.", 12, 40);
        },
    }
    if (session.status.len > 0) try text(ui, session.status, 11, 0);
}
fn list(ui: *app.Ui, model: *const lib.Model) !void {
    const is_library = model.screen == .library;
    const count = if (is_library) model.titleCount() else model.library.manga[model.manga].chapters.len;
    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = .all(10), .child_gap = 4 } });
        defer ui.close();
        if (is_library) try app.widgets.searchField(ui, "query", .{ .text = model.query_text, .placeholder = "Search title or author", .on_change = ui.messages(Root).handler(.query) });
        if (!is_library) try text(ui, model.library.manga[model.manga].title, 17, 0);
        try ui.print(.{ .font_size = 12, .color = .gray(60) }, "{d} {s}  /  Offline library", .{ count, if (is_library) "titles" else "chapters" });
    }
    {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .x(10), .child_gap = 4 } });
        defer ui.close();
        if (count == 0) {
            try text(ui, if (model.query_text.len > 0) "No matching titles" else "Your next story starts here", 18, 0);
            try text(ui, "Add manga with pocketmanga-sync.", 12, 60);
            try text(ui, "Tap Browse for the library location.", 12, 60);
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
                try ui.print(.{ .font_size = 10, .color = .gray(60) }, "{d} pages  /  {s}", .{ ch.pages.len, if (ch.pages.len == 0) "Not downloaded" else if (p) |v| if (v.completed) "Read" else "Reading" else "Unread" });
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
