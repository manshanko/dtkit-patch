const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

const root = @import("root");
const process = @import("zig-std/process.zig");

const is_windows = builtin.os.tag == .windows;

pub const OsStr = if (is_windows)
    [:0]const u16
else
    [:0]const u8;

pub const OsStrMut = if (is_windows)
    [:0]u16
else
    [:0]u8;

pub fn into_os_str(comptime str: [:0]const u8) OsStr {
    return if (is_windows)
        std.unicode.utf8ToUtf16LeStringLiteral(str)
    else
        str;
}

pub fn stderr() std.fs.File {
    return if (@hasDecl(std.fs.File, "stderr"))
        std.fs.File.stderr()
    else
        std.io.getStdErr();
}

pub fn path_join(allocator: std.mem.Allocator, dir_os: OsStr, part: OsStr) error{OutOfMemory, BadPathName}!OsStr {
    if (is_windows) {
        const last = dir_os[dir_os.len - 1];
        const no_slash: u32 = if (last == '\\' or last == '/') 0 else 1;

        var tmp: [0]u16 = undefined;
        const size_new = windows.ntdll.RtlGetFullPathName_U(
            dir_os,
            0,
            &tmp,
            null,
        );
        if (size_new <= 2) return error.BadPathName;

        var buffer = try allocator.allocSentinel(u16, 4 + (size_new / 2 - 1) + no_slash + part.len, 0);
        errdefer if (!root.leak_resources) allocator.free(buffer);

        const size = windows.ntdll.RtlGetFullPathName_U(
            dir_os,
            size_new,
            buffer[4..].ptr,
            null,
        );
        if (size == 0) return error.BadPathName;

        buffer[0] = '\\';
        buffer[1] = '?';
        buffer[2] = '?';
        buffer[3] = '\\';

        var offset: usize = 4 + size / 2;
        if (no_slash == 1) {
            buffer[offset] = '\\';
            offset += 1;
        }
        @memcpy(buffer[offset..offset + part.len], part);
        offset += part.len;
        buffer[offset] = 0;
        if (!root.leak_resources and offset != buffer.len) {
            const buffer2 = try allocator.dupeZ(u16, buffer[0..offset]);
            allocator.free(buffer);
            buffer = buffer2;
        } else {
            buffer = buffer[0..offset :0];
        }
        return buffer;
    } else {
        const buffer = try allocator.allocSentinel(u8, dir_os.len + 1 + part.len, 0);
        @memcpy(buffer[0..dir_os.len], dir_os);

        var offset: usize = dir_os.len;
        if (buffer[offset] != '/') {
            buffer[offset] = '/';
            offset += 1;
        }
        @memcpy(buffer[offset..offset + part.len], part);
        offset += part.len;
        return buffer;
    }
}

pub fn fs_rename(old: OsStr, new: OsStr) std.posix.RenameError!void {
    return if (is_windows)
        std.posix.renameW(old, new)
    else
        std.posix.renameZ(old, new);
}

pub fn fs_createFile(path: OsStr) std.fs.File.OpenError!std.fs.File {
    return if (is_windows)
        std.fs.cwd().createFileW(path, .{})
    else
        return std.fs.cwd().createFileZ(path, .{});
}

pub fn fs_openFile(path: OsStr) std.fs.File.OpenError!std.fs.File {
    return if (is_windows)
        std.fs.cwd().openFileW(path, .{})
    else
        std.fs.cwd().openFileZ(path, .{});
}

pub const ReadFileError = error{OutOfMemory}
    || std.fs.File.GetSeekPosError
    || std.fs.File.OpenError
    || std.posix.ReadError;

pub fn read_file(allocator: std.mem.Allocator, path: OsStr) ReadFileError![:0]u8 {
    const file = try fs_openFile(path);
    // Must close file to rename without unlinking.
    defer file.close();

    const size = try file.getEndPos();
    const data = try allocator.allocSentinel(u8, size, 0);
    errdefer if (!root.leak_resources) allocator.free(data);

    _ = try file.readAll(data[0..size]);
    return data;
}

pub const ArgIterator = struct {
    const Self = @This();

    const Iter = if (is_windows) process.ArgIteratorWindows else std.process.ArgIteratorPosix;

    inner: Iter,

    pub fn init(allocator: std.mem.Allocator) !Self {
        if (is_windows) {
            const cmd_line = windows.peb().ProcessParameters.CommandLine;
            const cmd_line_w = cmd_line.Buffer.?[0 .. cmd_line.Length / 2];
            const args = try process.ArgIteratorWindows.init(allocator, cmd_line_w);
            return .{
                .inner = args,
            };
        } else {
            return .{
                .inner = std.process.ArgIteratorPosix.init(),
            };
        }
    }

    pub fn deinit(self: *Self) void {
        if (is_windows) self.inner.deinit();
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

        return if (msg_type == .Prompt)
            result == IDYES
        else
            result == IDOK;
    }
    return false;
}
