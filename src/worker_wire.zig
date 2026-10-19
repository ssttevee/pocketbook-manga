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

fn stream(fd: c_int) std.Io.net.Stream {
    return .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } };
}
pub fn sendIo(io: std.Io, fd: c_int, gpa: std.mem.Allocator, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(bytes);
    if (bytes.len > p.max_frame) return error.ProtocolFrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    var writer = stream(fd).writer(io, &.{});
    writer.interface.writeAll(&header) catch return writer.err orelse error.WorkerCrashed;
    writer.interface.writeAll(bytes) catch return writer.err orelse error.WorkerCrashed;
}
fn readAllIo(io: std.Io, fd: c_int, buffer: []u8) !void {
    var at: usize = 0;
    while (at < buffer.len) {
        var data: [1][]u8 = .{buffer[at..]};
        const result = stream(fd).readWithControl(io, &data, &.{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.WorkerCrashed,
        };
        if (result.data_len == 0) return error.WorkerCrashed;
        at += result.data_len;
    }
}
pub fn receiveIo(comptime T: type, io: std.Io, fd: c_int, gpa: std.mem.Allocator) !T {
    var header: [4]u8 = undefined;
    try readAllIo(io, fd, &header);
    const len = std.mem.readInt(u32, &header, .little);
    if (len == 0 or len > p.max_frame) return error.InvalidProtocolFrame;
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    try readAllIo(io, fd, bytes);
    return std.json.parseFromSliceLeaky(T, gpa, bytes, .{ .allocate = .alloc_always });
}

extern "c" fn pm_send_now(c_int, [*]const u8, usize) isize;
pub fn cancelNow(fd: c_int, id: u64) void {
    var frame: [128]u8 = undefined;
    const bytes = std.fmt.bufPrint(frame[4..], "{{\"version\":{d},\"id\":{d},\"kind\":\"cancel\"}}", .{ p.version, id }) catch return;
    std.mem.writeInt(u32, frame[0..4], @intCast(bytes.len), .little);
    _ = pm_send_now(fd, &frame, bytes.len + 4);
}
fn responseDeadline(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(300), .awake);
}
fn receiveResponse(io: std.Io, fd: c_int, a: std.mem.Allocator) !p.Response {
    return receiveIo(p.Response, io, fd, a);
}
pub fn receiveTimed(io: std.Io, fd: c_int, a: std.mem.Allocator) !p.Response {
    const Result = union(enum) { response: anyerror!p.Response, deadline: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select: std.Io.Select(Result) = .init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.response, receiveResponse, .{ io, fd, a });
    try select.concurrent(.deadline, responseDeadline, .{io});
    return switch (try select.await()) {
        .response => |result| result,
        .deadline => |result| {
            try result;
            return error.WorkerTimedOut;
        },
    };
}
