const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

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

pub const ArgIterator = struct {
    const Self = @This();

    inner: process.ArgIteratorWindows,

    pub fn init(allocator: std.mem.Allocator) !Self {
        const cmd_line = windows.peb().ProcessParameters.CommandLine;
        const cmd_line_w = cmd_line.Buffer.?[0 .. cmd_line.Length / 2];
        const args = try process.ArgIteratorWindows.init(allocator, cmd_line_w);
        return .{
            .inner = args,
        };
    }

    pub fn next(self: *Self) ?OsStr {
        return self.inner.next();
    }
};

extern "kernel32" fn GetConsoleProcessList(
    lpdwProcessList: [*]windows.DWORD,
    dwProcessCount: windows.DWORD,
) callconv(.winapi) windows.DWORD;

// based on https://stackoverflow.com/a/3448740
pub fn console_will_close() bool {
    if (is_windows) {
        var list: [1]windows.DWORD = undefined;
        const count = GetConsoleProcessList(&list, list.len);
        return count == 1;
    } else {
        return false;
    }
}

extern "user32" fn MessageBoxA(
    hWnd: ?windows.HWND,
    lpText: ?windows.LPCSTR,
    lpCaption: ?windows.LPCSTR,
    uType: u32,
) callconv(.winapi) i32;

pub const MessageType = enum {
    Notify,
    NotifyError,
    Prompt,
};

pub fn display_message(msg: [:0]const u8, msg_type: MessageType) bool {
    if (is_windows) {
        const MB_OK: u32 = 0;
        const MB_YESNO: u32 = 4;
        const MB_ICONERROR: u32 = 0x10;
        const MB_DEFBUTTON2: u32 = 0x100;
        const IDOK: u32 = 1;
        const IDYES: u32 = 6;

        const mode = switch (msg_type) {
            .Notify => MB_OK,
            .NotifyError => MB_OK | MB_ICONERROR,
            .Prompt => MB_YESNO | MB_DEFBUTTON2,
        };

        const result = MessageBoxA(
            null,
            msg,
            "dtkit-path",
            mode,
        );

        if (msg_type == .Prompt) {
            return result == IDYES;
        } else {
            return result == IDOK;
        }
    }
    return false;
}
