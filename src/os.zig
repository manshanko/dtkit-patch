const builtin = @import("builtin");
const std = @import("std");

const process = @import("zig-std/process.zig");

const mem = @import("mem.zig");

const is_windows = builtin.os.tag == .windows;

pub const OsStr = if (is_windows) res: {
    break :res [:0]const u16;
} else res: {
    break :res [:0]const u8;
};

pub fn into_os_str(comptime str: [:0]const u8) OsStr {
    return std.unicode.utf8ToUtf16LeStringLiteral(str);
}

pub fn path_join(allocator: std.mem.Allocator, dir: OsStr, part: OsStr) !OsStr {
    var size = dir.len + part.len;
    if (dir[dir.len - 1] != '\\') {
        size += 1;
    }
    const buffer = try allocator.allocSentinel(u16, size, 0);
    mem.memcpy(buffer[0..dir.len], dir);
    var off = dir.len;
    if (dir[dir.len - 1] != '\\') {
        buffer[dir.len] = '\\';
        off += 1;
    }
    mem.memcpy(buffer[off..], part);
    return buffer;
}

pub fn fs_unlink(path: OsStr) !void {
    return std.posix.unlinkW(path);
}

pub fn fs_rename(old: OsStr, new: OsStr) !void {
    return std.posix.renameW(old, new);
}

pub fn fs_createFile(path: OsStr) !std.fs.File {
    return std.fs.cwd().createFileW(path, .{});
}

pub fn fs_openFile(path: OsStr) !std.fs.File {
    return std.fs.cwd().openFileW(path, .{});
}
