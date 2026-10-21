//! Called only by the InkView event thread; no firmware imports are required.
const std = @import("std");
const Preventor = extern struct { name: [*:0]const u8, forbidden: bool };
const Sleep = *const fn (*Preventor) callconv(.c) void;
const Postpone = *const fn () callconv(.c) c_int;
const Ban = *const fn (c_int) callconv(.c) void;
pub const Guard = struct {
    start: ?Sleep = null,
    stop: ?Sleep = null,
    postpone: ?Postpone = null,
    ban: ?Ban = null,
    preventor: Preventor = .{ .name = "PocketManga background work", .forbidden = false },
    active: bool = false,
    next_tick: u64 = 0,
    pub fn load(library: *std.DynLib) Guard {
        return .{
            .start = library.lookup(Sleep, "iv_sleep_preventor_start"),
            .stop = library.lookup(Sleep, "iv_sleep_preventor_stop"),
            .postpone = library.lookup(Postpone, "PostponeTimedPoweroff"),
            .ban = library.lookup(Ban, "BanSleep"),
        };
    }
    /// A paired preventor remains active until stopped; BanSleep expires.
    pub fn persistent(self: Guard) bool {
        return self.start != null and self.stop != null;
    }
    pub fn update(self: *Guard, active: bool, now: u64) void {
        const paired = self.persistent();
        if (active != self.active) {
            self.active = active;
            if (paired) {
                if (active) self.start.?(&self.preventor) else self.stop.?(&self.preventor);
            }
            if (!active and !paired) if (self.ban) |ban| ban(0);
            self.next_tick = 0;
        }
        if (!active or now < self.next_tick) return;
        // The preventor refreshes its own firmware timer. Power-off uses a
        // separate inactivity clock, which background network I/O never resets.
        if (self.postpone) |postpone| _ = postpone();
        if (!paired) if (self.ban) |ban| ban(10);
        self.next_tick = now + 5_000;
    }
};

/// The event thread combines both sources so finishing one cannot release
/// sleep prevention while the other still has background work.
pub const Activity = struct {
    guard: Guard = .{},
    online: bool = false,
    tasks: bool = false,
    pub fn updateOnline(self: *Activity, active: bool, now: u64) void {
        self.online = active;
        self.guard.update(self.online or self.tasks, now);
    }
    pub fn updateTasks(self: *Activity, active: bool, now: u64) void {
        self.tasks = active;
        self.guard.update(self.online or self.tasks, now);
    }
};

const Fake = struct {
    var starts: usize = 0;
    var stops: usize = 0;
    var ticks: usize = 0;
    var bans: usize = 0;
    fn start(p: *Preventor) callconv(.c) void {
        starts += 1;
        p.forbidden = true;
    }
    fn stop(p: *Preventor) callconv(.c) void {
        stops += 1;
        p.forbidden = false;
    }
    fn postpone() callconv(.c) c_int {
        ticks += 1;
        return 0;
    }
    fn ban(seconds: c_int) callconv(.c) void {
        std.debug.assert(seconds == 10 or seconds == 0);
        if (seconds == 10) bans += 1;
    }
};
test "power guard balances sleep prevention and ticks only during jobs" {
    Fake.starts = 0;
    Fake.stops = 0;
    Fake.ticks = 0;
    var guard: Guard = .{ .start = Fake.start, .stop = Fake.stop, .postpone = Fake.postpone };
    guard.update(false, 0);
    guard.update(true, 100);
    guard.update(true, 200);
    guard.update(true, 5_100);
    try std.testing.expect(guard.preventor.forbidden);
    try std.testing.expectEqual(1, Fake.starts);
    try std.testing.expectEqual(2, Fake.ticks);
    guard.update(false, 5_200);
    guard.update(false, 20_000);
    try std.testing.expect(!guard.preventor.forbidden);
    try std.testing.expectEqual(1, Fake.stops);
    try std.testing.expectEqual(2, Fake.ticks);
    guard.update(true, 20_001);
    guard.update(false, 20_002);
    try std.testing.expectEqual(2, Fake.starts);
    try std.testing.expectEqual(2, Fake.stops);
}
test "optional power symbols may be missing or unpaired" {
    Fake.bans = 0;
    var missing: Guard = .{};
    missing.update(true, 0);
    missing.update(false, 1);
    var fallback: Guard = .{ .start = Fake.start, .ban = Fake.ban };
    fallback.update(true, 0);
    fallback.update(true, 5_000);
    fallback.update(false, 5_001);
    try std.testing.expect(!fallback.preventor.forbidden);
    try std.testing.expectEqual(2, Fake.bans);
}

test "online and decoder activity release sleep prevention only when both finish" {
    Fake.starts = 0;
    Fake.stops = 0;
    Fake.ticks = 0;
    var activity: Activity = .{ .guard = .{ .start = Fake.start, .stop = Fake.stop, .postpone = Fake.postpone } };
    activity.updateOnline(true, 0);
    activity.updateTasks(true, 1);
    activity.updateOnline(false, 2);
    try std.testing.expect(activity.guard.active);
    try std.testing.expectEqual(@as(usize, 0), Fake.stops);
    activity.updateTasks(false, 3);
    try std.testing.expect(!activity.guard.active);
    activity.updateTasks(true, 4);
    activity.updateOnline(true, 5);
    activity.updateTasks(false, 6);
    try std.testing.expect(activity.guard.active);
    activity.updateOnline(false, 7);
    try std.testing.expect(!activity.guard.active);
    try std.testing.expectEqual(@as(usize, 2), Fake.starts);
    try std.testing.expectEqual(@as(usize, 2), Fake.stops);
}
