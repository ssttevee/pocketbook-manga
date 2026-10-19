//! Bounded length-prefixed JSON over the private Unix socketpair.
const std = @import("std");
const p = @import("protocol.zig");
extern "c" fn pm_poll(c_int, c_int) c_int;
extern "c" fn pm_send(c_int, [*]const u8, usize) isize;
extern "c" fn pm_recv(c_int, [*]u8, usize) isize;
pub extern "c" fn pm_now_ms() u64;
pub extern "c" fn pm_rss_kib() usize;

pub fn ready(fd: c_int, timeout_ms: c_int) !bool {
    const n = pm_poll(fd, timeout_ms);
    if (n < 0) return error.WorkerCrashed;
    return n > 0;
}
pub fn send(fd: c_int, gpa: std.mem.Allocator, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(bytes);
    if (bytes.len > p.max_frame) return error.ProtocolFrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    for ([_][]const u8{ &header, bytes }) |part| {
        var at: usize = 0;
        while (at < part.len) {
            const n = pm_send(fd, part[at..].ptr, part.len - at);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            if (n <= 0) return error.WorkerCrashed;
            at += @intCast(n);
        }
    }
}
fn readAll(fd: c_int, buffer: []u8) !void {
    var at: usize = 0;
    while (at < buffer.len) {
        if (!try ready(fd, 300_000)) return error.WorkerTimedOut;
        const n = pm_recv(fd, buffer[at..].ptr, buffer.len - at);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.WorkerCrashed;
        at += @intCast(n);
    }
}
pub fn receive(comptime T: type, fd: c_int, gpa: std.mem.Allocator) !T {
    var header: [4]u8 = undefined;
    try readAll(fd, &header);
    const len = std.mem.readInt(u32, &header, .little);
    if (len == 0 or len > p.max_frame) return error.InvalidProtocolFrame;
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    try readAll(fd, bytes);
    return std.json.parseFromSliceLeaky(T, gpa, bytes, .{ .allocate = .alloc_always });
}
