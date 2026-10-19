//! Kernel 3.10 I/O for both the native glibc 2.23 UI and the glibc 2.39 worker.
//! The C bridge owns fstat/fstatat ABI details; unchanged vtable entries keep
//! Threaded's original userdata. No Zig metadata/entropy syscall is required.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const builtin = @import("builtin");

pub const DeviceIo = struct {
    base: Io,
    vtable: Io.VTable,

    pub fn init(base: Io) DeviceIo {
        var result: DeviceIo = .{ .base = base, .vtable = base.vtable.* };
        if (builtin.os.tag == .linux) {
            result.vtable.fileStat = fileStat;
            result.vtable.dirStat = dirStat;
            result.vtable.dirStatFile = dirStatFile;
            result.vtable.randomSecure = randomSecure;
            result.vtable.random = random;
            result.vtable.fileLength = fileLength;
            result.vtable.dirCreateDirPath = createDirPath;
            result.vtable.dirCreateDirPathOpen = createDirPathOpen;
        }
        return result;
    }

    pub fn io(self: *const DeviceIo) Io {
        return .{ .userdata = self.base.userdata, .vtable = &self.vtable };
    }
};

fn threaded(userdata: ?*anyopaque) Io {
    const t: *Io.Threaded = @ptrCast(@alignCast(userdata));
    return t.io();
}

fn fileLength(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
    // Route length through the C stat bridge on both glibc targets.
    return (try fileStat(userdata, file)).size;
}

fn createDirPath(userdata: ?*anyopaque, dir: Dir, path: []const u8, permissions: Dir.Permissions) Dir.CreateDirPathError!Dir.CreatePathStatus {
    const io = threaded(userdata);
    var it = Dir.path.componentIterator(path);
    var status: Dir.CreatePathStatus = .existed;
    var component = it.last() orelse return error.BadPathName;
    while (true) {
        if (dir.createDir(io, component.path, permissions)) |_| {
            status = .created;
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                // Do not follow a dangling symlink and loop forever.
                const stat = try dirStatFile(userdata, dir, component.path, .{ .follow_symlinks = false });
                if (stat.kind != .directory) return error.NotDir;
            },
            error.FileNotFound => |e| {
                component = it.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        }
        component = it.next() orelse return status;
    }
}

fn createDirPathOpen(userdata: ?*anyopaque, dir: Dir, path: []const u8, permissions: Dir.Permissions, options: Dir.OpenOptions) Dir.CreateDirPathOpenError!Dir {
    const io = threaded(userdata);
    return dir.openDir(io, path, options) catch |err| switch (err) {
        error.FileNotFound => {
            _ = try createDirPath(userdata, dir, path, permissions);
            return dir.openDir(io, path, options);
        },
        else => |e| return e,
    };
}

const Stat = extern struct {
    ino: u64,
    nlink: u64,
    size: u64,
    atime_s: i64,
    mtime_s: i64,
    ctime_s: i64,
    atime_ns: u64,
    mtime_ns: u64,
    ctime_ns: u64,
    block_size: u64,
    mode: u32,
};
extern "c" fn pm_stat(c_int, ?[*:0]const u8, c_int, *Stat) c_int;
extern "c" fn pm_entropy([*]u8, usize) c_int;
fn convert(st: Stat) Io.File.Stat {
    return .{
        .inode = st.ino,
        .nlink = @intCast(st.nlink),
        .size = st.size,
        .permissions = .fromMode(@intCast(st.mode)),
        .kind = Io.Threaded.statxKind(@intCast(st.mode)),
        .atime = .{ .nanoseconds = @intCast(@as(i128, st.atime_s) * std.time.ns_per_s + st.atime_ns) },
        .mtime = .{ .nanoseconds = @intCast(@as(i128, st.mtime_s) * std.time.ns_per_s + st.mtime_ns) },
        .ctime = .{ .nanoseconds = @intCast(@as(i128, st.ctime_s) * std.time.ns_per_s + st.ctime_ns) },
        .block_size = @intCast(st.block_size),
    };
}
fn fileStat(_: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
    var st: Stat = undefined;
    const result = pm_stat(file.handle, null, 0, &st);
    if (result == 0) return convert(st);
    if (result == @backingInt(std.c.E.NOMEM)) return error.SystemResources;
    if (result == @backingInt(std.c.E.ACCES)) return error.AccessDenied;
    return error.Unexpected;
}
fn dirStat(userdata: ?*anyopaque, dir: Dir) Dir.StatError!Dir.Stat {
    if (dir.handle == std.posix.AT.FDCWD) return dirStatFile(userdata, dir, ".", .{}) catch return error.Unexpected;
    return fileStat(userdata, .{ .handle = dir.handle, .flags = .{ .nonblocking = false } });
}
fn dirStatFile(_: ?*anyopaque, dir: Dir, path: []const u8, options: Dir.StatFileOptions) Dir.StatFileError!Io.File.Stat {
    if (path.len >= std.posix.PATH_MAX) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    var st: Stat = undefined;
    const result = pm_stat(dir.handle, @ptrCast(&buffer), @intFromBool(!options.follow_symlinks), &st);
    if (result == 0) return convert(st);
    const errno: std.c.E = @fromBackingInt(@as(u16, @intCast(result)));
    return switch (errno) {
        .NOENT, .NOTDIR => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOMEM => error.SystemResources,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}
fn randomSecure(_: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    if (pm_entropy(buffer.ptr, buffer.len) != 0) return error.EntropyUnavailable;
}

fn random(userdata: ?*anyopaque, buffer: []u8) void {
    randomSecure(userdata, buffer) catch threaded(userdata).vtable.random(userdata, buffer);
}
