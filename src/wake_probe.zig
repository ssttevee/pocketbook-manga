//! Standalone physical-reader check. No reader data or production settings load.
//! The host's periodic task fallback is disabled; completion uses SendEvent.
const std = @import("std");
const f = @import("fabrum");
const ink = @import("fabrum-platform-inkview");
const Power = @import("power.zig");
const Root = @This();
const Host = ink.App(Root);
const Timing = struct { started: std.Io.Timestamp, ready: std.Io.Timestamp };
pub const State = struct { finished: bool = false, trial: u8 = 0 };
pub const Props = struct {};
pub const Msg = union(enum) { completed: std.Io.Cancelable!Timing, quit };
var io: std.Io = undefined;
var guard: Power.Guard = .{};
var guard_enabled = true;
var touched = false;
var environment_clear = false;
var completed = false;
var passed_trials: u8 = 0;
var hard_timers: usize = 0;
var actual_main: *const fn (ink.inkview.Handler) callconv(.c) void = undefined;
var actual_close: *const fn () callconv(.c) void = undefined;
var actual_timer: @FieldType(ink.inkview.Api, "SetHardTimer") = undefined;
var app_handler: ink.inkview.Handler = undefined;
const Status = *const fn () callconv(.c) c_int;
const status_names = [_][:0]const u8{ "GetSleepmode", "IsUSBconnected", "QueryNetwork" };
var statuses: [status_names.len]?Status = @splat(null);
var sleep_mode: *const fn (c_int) callconv(.c) void = undefined;

fn work(task: *f.app.Task) std.Io.Cancelable!Timing {
    const started = std.Io.Clock.boot.now(task.io);
    // Pass the firmware's startup/input/e-ink grace periods before posting.
    try task.io.sleep(.fromMilliseconds(3000), .awake);
    try task.checkCancel();
    const ready = std.Io.Clock.boot.now(task.io);
    std.debug.print("WAKE_PROBE worker ready elapsed_ms={d}\n", .{started.durationTo(ready).toMilliseconds()});
    return .{ .started = started, .ready = ready };
}
pub fn update(state: *State, msg: Msg, ctx: *f.app.Update(Root)) !void {
    switch (msg) {
        .quit => try ctx.quit(),
        .completed => |result| {
            const timing = result catch |err| {
                std.debug.print("WAKE_PROBE worker error={s}\n", .{@errorName(err)});
                try ctx.quit();
                return;
            };
            const now = std.Io.Clock.boot.now(io);
            const delivery_ms = timing.ready.durationTo(now).toMilliseconds();
            const total_ms = timing.started.durationTo(now).toMilliseconds();
            const prompt = !touched and hard_timers == 0 and delivery_ms < 250 and total_ms < 4000;
            const pass = prompt and environment_clear;
            std.debug.print("WAKE_PROBE {s} trial={d}/3 guard={any} delivery_ms={d} total_ms={d} host_hard_timers={d} touched={any}\n", .{ if (pass) "PASS" else if (prompt) "INCONCLUSIVE" else "FAIL", state.trial + 1, guard_enabled, delivery_ms, total_ms, hard_timers, touched });
            if (pass) passed_trials += 1;
            if (prompt and state.trial < 2) {
                state.trial += 1;
            } else {
                completed = true;
                state.finished = true;
                try ctx.quit();
            }
        },
    }
}
pub fn view(ui: *f.app.Ui, state: *const State, _: Props) !void {
    const on = ui.messages(Root);
    try ui.open("probe", .{ .layout = .{ .axis = .y, .sizing = .grow(.{}), .padding = .all(18), .child_gap = 16 }, .background_color = .white });
    defer ui.close();
    try ui.text("PocketManga wake test", .{ .font_size = 23 });
    try ui.text("Do not touch the reader. This should close itself after nine seconds.", .{ .font_size = 17 });
    try ui.text("If still open after fifteen seconds, press Back or Close. Results are saved in the probe log.", .{ .font_size = 15 });
    try f.app.widgets.button(ui, "close", .{ .label = "Close", .on_click = on.bind(.quit) });
    if (!state.finished) try ui.task("wake-test", .{ .restart = state.trial }, work, .{}, on.handler(.completed));
}
fn activity(active: bool) void {
    if (guard_enabled) guard.update(active, @intCast(std.Io.Clock.boot.now(io).toMilliseconds()));
}
fn mainLoop(handler: ink.inkview.Handler) callconv(.c) void {
    app_handler = handler;
    actual_main(events);
}
fn events(kind: c_int, p1: c_int, p2: c_int) callconv(.c) c_int {
    const event: ink.inkview.Event = @fromBackingInt(@intCast(kind));
    if (event == .init) {
        sleep_mode(1); // Process-local; never written to the user configuration.
        var values: [status_names.len]?c_int = @splat(null);
        for (status_names, statuses, &values) |name, status, *value| {
            if (status) |query| {
                value.* = query();
                std.debug.print("WAKE_PROBE {s}={d}\n", .{ name, value.*.? });
            }
        }
        // QueryNetwork low bits describe installed radios, not connectivity.
        const offline = if (values[2]) |network| network >= 0 and network & 0x0f00 == 0 else false;
        environment_clear = values[0] == 1 and values[1] == 0 and offline;
    }
    switch (event) {
        .key_press, .key_release, .key_repeat, .prev_page, .next_page, .pointer_down, .pointer_up, .pointer_move, .pointer_drag, .pointer_long, .pointer_hold, .pointer_cancel => touched = true,
        else => {},
    }
    return app_handler(kind, p1, p2);
}
fn close() callconv(.c) void {
    if (!completed) std.debug.print("WAKE_PROBE ABORT: completion did not arrive before close; touched={any}\n", .{touched});
    guard.update(false, 0);
    actual_close();
}
fn hardTimer(name: [*:0]const u8, callback: ink.inkview.TimerProc, ms: c_int) callconv(.c) void {
    hard_timers += 1;
    std.debug.print("WAKE_PROBE unexpected host hard timer {s} ms={d}\n", .{ std.mem.span(name), ms });
    actual_timer(name, callback, ms);
}
pub fn main(init: std.process.Init) !void {
    var device_io = @import("device_io.zig").DeviceIo.init(init.io);
    io = device_io.io();
    var args = init.minimal.args.iterate();
    _ = args.next();
    if (args.next()) |mode| {
        if (!std.mem.eql(u8, mode, "--guard-off")) return error.InvalidProbeMode;
        guard_enabled = false;
    }
    const library_name = init.minimal.environ.getPosix("INKVIEW_LIBRARY") orelse "libinkview.so";
    var library = try std.DynLib.open(library_name);
    guard = Power.Guard.load(&library);
    defer guard.update(false, 0);
    if (guard_enabled and !(guard.start != null and guard.stop != null) and guard.ban == null) return error.NoSleepProtection;
    sleep_mode = library.lookup(@TypeOf(sleep_mode), "iv_sleepmode") orelse return error.MissingSleepMode;
    std.debug.print("WAKE_PROBE start guard={any} paired_preventor={any} ban={any}; periodic polling DISABLED\n", .{ guard_enabled, guard.start != null and guard.stop != null, guard.ban != null });
    for (status_names, &statuses) |name, *status| status.* = library.lookup(Status, name);
    var api = try ink.inkview.Api.load(library_name);
    actual_main = api.InkViewMain;
    actual_close = api.CloseApp;
    actual_timer = api.SetHardTimer;
    api.InkViewMain = mainLoop;
    api.CloseApp = close;
    api.SetHardTimer = hardTimer;
    try Host.run(init.gpa, io, api, .{}, .{
        .task_poll_interval_ms = null,
        .task_activity = activity,
        .close_key = .back,
        .fonts = &.{.{ .name = "Go", .data = @embedFile("fonts/Go-Regular.ttf") }},
        .refresh = .{ .full_every = 0, .interactive = .dynamic },
    });
}

test "standalone wake probe completes three real tasks without host hard timers" {
    io = std.testing.io;
    guard = .{};
    guard_enabled = true;
    touched = false;
    completed = false;
    passed_trials = 0;
    hard_timers = 0;
    environment_clear = false;
    const Noop = struct {
        fn sleepMode(_: c_int) callconv(.c) void {}
        fn enabled() callconv(.c) c_int {
            return 1;
        }
        fn zero() callconv(.c) c_int {
            return 0;
        }
        fn offlineRadio() callconv(.c) c_int {
            return 2; // NET_WIFI hardware present, NET_CONNECTED clear.
        }
        fn send(_: ink.inkview.Handler, kind: c_int, p1: c_int, p2: c_int) callconv(.c) void {
            // Real InkView accepts a handler distinct from its main wrapper.
            // The fake requires that wrapper, which forwards to the host.
            ink.fake.api().SendEvent(ink.fake.state.handler.?, kind, p1, p2);
        }
    };
    sleep_mode = Noop.sleepMode;
    statuses = .{ Noop.enabled, Noop.zero, Noop.offlineRadio };
    try ink.fake.init(std.testing.allocator, .{});
    defer ink.fake.deinit();
    var api = ink.fake.api();
    actual_main = api.InkViewMain;
    actual_close = api.CloseApp;
    actual_timer = api.SetHardTimer;
    api.InkViewMain = mainLoop;
    api.CloseApp = close;
    api.SetHardTimer = hardTimer;
    api.SendEvent = Noop.send;
    try Host.run(std.testing.allocator, io, api, .{}, .{
        .task_poll_interval_ms = null,
        .task_activity = activity,
        .clock = ink.fake.clock,
        .fonts = &.{.{ .name = "Go", .data = @embedFile("fonts/Go-Regular.ttf") }},
        .refresh = .{ .full_every = 0, .interactive = .dynamic },
    });
    defer Host.instance.deinit();
    for (0..3) |_| {
        // Fake InkView's queue is main-thread-owned. Join the producer before
        // pumping, while retaining the real concurrent task/host wake path.
        const records = Host.instance.runtime.core.tasks.records.items;
        try std.testing.expect(records.len > 0);
        try records[records.len - 1].group.await(io);
        ink.fake.pump();
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(u8, 3), passed_trials);
    try std.testing.expectEqual(@as(usize, 0), hard_timers);
    try std.testing.expect(ink.fake.state.closed);
    try std.testing.expect(!guard.active);
}
