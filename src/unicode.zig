const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

extern "kernel32" fn MultiByteToWideChar(
    CodePage: windows.UINT,
    dwFlags: windows.DWORD,
    lpMultiByteStr: [*]const u8,
    cbMultiByte: c_int,
    lpWideCharStr: [*]u16, //windows.LPWSTR,
    cchWideChar: c_int,
) callconv(.winapi) c_int;

pub fn utf8_to_utf16(utf8: []const u8, utf16: []u16) error{InvalidUtf8}!usize {
    if (builtin.os.tag != .windows) @compileError("utf8_to_utf16 only supports windows");

    const size = MultiByteToWideChar(
        65001, //CP_UTF8
        0,
        utf8.ptr,
        @intCast(utf8.len),
        utf16.ptr,
        @intCast(utf16.len - 1),
    );
    if (size <= 0) return error.InvalidUtf8;
    return @intCast(size);
}
