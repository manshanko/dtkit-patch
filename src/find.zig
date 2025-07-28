// Use Win32 ASCII api when possible to reduce static string size in binary.
// We return WTF-16 since it'll be joined with a path later which is WTF-16.
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

const root = @import("root");
const mem = @import("mem.zig");
const os = @import("os.zig");
const OsStr = os.OsStr;

const darktide_class_path =
    \\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Families\FatsharkAB.Warhammer40000DarktideNew_hwm6pnepa3ng2
;
const registry_package_full_name =
    \\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateRepository\Cache\Package\Index\PackageFullName
;
const registry_package_index =
    \\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateRepository\Cache\Package\Data
;
const installed_location = os.into_os_str("InstalledLocation");

const steam_current_user =
    \\SOFTWARE\Valve\Steam
;
const steam_local_machine =
    \\SOFTWARE\\WOW6432Node\\Valve\\Steam
;
const steam_path = os.into_os_str("SteamPath");
const install_path = os.into_os_str("InstallPath");
const library_vdf = if (builtin.os.tag == .windows) path: {
    break :path os.into_os_str("steamapps\\libraryfolders.vdf");
} else {
    @compileError("currently only windows is supported");
};

const REG_SZ = 1;

pub extern "advapi32" fn RegOpenKeyExA(
    hKey: windows.HKEY,
    lpSubKey: windows.LPCSTR,
    ulOptions: windows.DWORD,
    samDesired: windows.REGSAM,
    phkResult: *windows.HKEY,
) callconv(.winapi) windows.LSTATUS;

pub extern "advapi32" fn RegEnumKeyExA(
    hKey: windows.HKEY,
    dwIndex: windows.DWORD,
    lpName: windows.LPSTR,
    lpcchName: *windows.DWORD,
    lpReserved: ?*windows.DWORD,
    lpClass: ?windows.LPSTR,
    lpcchClass: ?*windows.DWORD,
    lpftLastWriteTime: ?*anyopaque, //PFILETIME
) callconv(.winapi) windows.LSTATUS;

pub extern "advapi32" fn RegQueryValueExW(
    hKey: windows.HKEY,
    lpValueName: ?windows.LPCWSTR,
    lpReserved: ?*windows.DWORD,
    lpType: ?*windows.DWORD,
    lpData: ?[*]u8, //LPBYTE
    lpcbData: ?*windows.DWORD,
) callconv(.winapi) windows.LSTATUS;

fn open_key(key: windows.HKEY, path: [:0]const u8) error{KeyNotFound}!windows.HKEY {
    var out_key: windows.HKEY = undefined;
    const err_int = RegOpenKeyExA(
        key,
        path,
        0,
        windows.KEY_QUERY_VALUE | windows.KEY_ENUMERATE_SUB_KEYS,
        &out_key,
    );
    if (err_int != 0) return error.KeyNotFound;
    return out_key;
}

fn key_first_enum(key: windows.HKEY, out: [:0]u8) error{KeyNotFound}!u32 {
    var size: windows.DWORD = @intCast(out.len);
    const err_int = RegEnumKeyExA(
        key,
        0,
        out,
        &size,
        null,
        null,
        null,
        null,
    );
    if (err_int != 0) return error.KeyNotFound;
    return size;
}

fn key_get_value(key: windows.HKEY, name: [:0]const u16, out: []u16) error{KeyNotFound, Unsupported}!u32 {
    var out_type: windows.DWORD = 0;
    const out_u8: []u8 = @ptrCast(out);
    var size: windows.DWORD = @intCast(out_u8.len);
    const err_int = RegQueryValueExW(
        key,
        name,
        null,
        &out_type,
        @ptrCast(out_u8),
        &size,
    );
    if (err_int != 0) return error.KeyNotFound;
    if (out_type != REG_SZ or size % 2 != 0) return error.Unsupported;
    const size_utf16 = size / 2;
    if (out[size_utf16] != 0) return error.Unsupported;
    for (0..size_utf16) |i| {
        if (out[i] == '/') out[i] = '\\';
    }
    return size_utf16 - 1;
}

pub fn find_darktide_gamepass(allocator: std.mem.Allocator) error{KeyNotFound, Unsupported, OutOfMemory}![:0]u16 {
    if (builtin.os.tag == .windows) {
        const apps_key = try open_key(windows.HKEY_CLASSES_ROOT, darktide_class_path);
        defer if (!root.leak_resources) { _ = windows.advapi32.RegCloseKey(apps_key); };

        var buffer: [2048:0]u8 = [_:0]u8{0} ** 2048;
        var offset = registry_package_full_name.len;
        mem.memcpy(buffer[0..offset], registry_package_full_name);
        buffer[offset] = '\\';
        offset += 1;
        const app_name = buffer[offset..];
        _ = try key_first_enum(apps_key, app_name);

        const indexes_key = try open_key(windows.HKEY_LOCAL_MACHINE, &buffer);
        defer if (!root.leak_resources) { _ = windows.advapi32.RegCloseKey(indexes_key); };

        offset = registry_package_index.len;
        mem.memcpy(buffer[0..offset], registry_package_index);
        buffer[offset] = '\\';
        offset += 1;
        const index = buffer[offset..];
        _ = try key_first_enum(indexes_key, index);

        const app_info_key = try open_key(windows.HKEY_LOCAL_MACHINE, &buffer);
        defer if (!root.leak_resources) { _ = windows.advapi32.RegCloseKey(app_info_key); };

        var out = try allocator.alloc(u16, 2048);
        errdefer if (!root.leak_resources) allocator.free(out);

        const size = try key_get_value(app_info_key, installed_location, out);
        out[size] = 0;
        return out[0..size :0];
    } else {
        @compileError("find_darktide_gamepass is only supported on windows");
    }
}

fn steam_dir_reg(out: []u16) error{KeyNotFound, Unsupported}!u32 {
    if (open_key(windows.HKEY_CURRENT_USER, steam_current_user)) |key| open: {
        return key_get_value(key, steam_path, out) catch break :open;
    } else |_| {}

    if (open_key(windows.HKEY_LOCAL_MACHINE, steam_local_machine)) |key| open: {
        return key_get_value(key, install_path, out) catch break :open;
    } else |_| {}

    return error.KeyNotFound;
}

fn read_file(allocator: std.mem.Allocator, path: OsStr) ![]u8 {
    const file = os.fs_openFile(path) catch |err| return switch (err) {
        error.FileNotFound => error.NotFoundDatabase,
        else => return err,
    };
    defer if (!root.leak_resources) file.close();

    const stat = try file.stat();
    const size = stat.size;

    const data = try allocator.alloc(u8, size);
    errdefer if (!root.leak_resources) allocator.free(data);

    const read = try file.readAll(data[0..size]);
    return data[0..read];
}

fn parse_string(data: []const u8, out: []u8) ?u32 {
    if (data[0] != '"') return null;

    var read: u32 = 1;
    var wrote: u32 = 0;
    while (read < data.len) {
        if (data[read] == '\\') {
            read += 1;
            out[wrote] = switch (data[read]) {
                '"', 'r', 'n', '\\' => data[read],
                else => return null,
            };
        } else if (data[read] == '"') {
            read += 1;
            break;
        } else {
            out[wrote] = data[read];
        }
        wrote += 1;
        read += 1;
    }

    if (wrote > 0) return wrote
    else return null;
}

// Slower and smaller (~1.5KiB) UTF-8 parser than std.unicode.utf8ToUtf16Le
fn bad_utf8_to_utf16(utf8: []const u8, utf16: []u16) !usize {
    var offset: u32 = 0;
    var dest_offset: u32 = 0;
    while (offset < utf8.len) {
        const prev_offset = offset;
        if (utf8[offset] < 0b10000000) {
            utf16[dest_offset] = utf8[offset] & 0b01111111;
            offset += 1;
            dest_offset += 1;
        } else if (utf8[offset] >= 0b11111000) {
            return error.InvalidUtf8;
        } else if (utf8[offset] >= 0b11110000) {
            const b0: u32 = utf8[offset    ] & 0b00000111;
            const b1: u32 = utf8[offset + 1] & 0b00111111;
            const b2: u32 = utf8[offset + 2] & 0b00111111;
            const b3: u32 = utf8[offset + 3] & 0b00111111;
            var cp = ((b0 << 18) | (b1 << 12) | (b2 << 6) | b3);
            if (cp <= 0xffff or cp > 0x10ffff) return error.InvalidUtf8;
            cp -= 0x10000;
            const high: u16 = @intCast(0xd800 + ((cp >> 10) & 0x3ff));
            const low: u16 = @intCast(0xdc00 + (cp & 0x3ff));
            utf16[dest_offset    ] = high;
            utf16[dest_offset + 1] = low;
            offset += 4;
            dest_offset += 2;
        } else if (utf8[offset] >= 0b11100000) {
            const b0: u16 = utf8[offset    ] & 0b00001111;
            const b1: u16 = utf8[offset + 1] & 0b00111111;
            const b2: u16 = utf8[offset + 2] & 0b00111111;
            const cp = (b0 << 12) | (b1 << 6) | b2;
            if (cp <= 0x7ff) return error.InvalidUtf8;
            if (cp >= 0xd800 and cp <= 0xdfff) return error.InvalidUtf8;
            utf16[dest_offset] = cp;
            offset += 3;
            dest_offset += 1;
        } else if (utf8[offset] >= 0b11000000) {
            const b0: u16 = utf8[offset    ] & 0b00011111;
            const b1: u16 = utf8[offset + 1] & 0b00111111;
            const cp = (b0 << 6) | b1;
            if (cp <= 0x7f) return error.InvalidUtf8;
            utf16[dest_offset] = cp;
            offset += 2;
            dest_offset += 1;
        } else {
            return error.InvalidUtf8;
        }

        for (prev_offset + 1..offset) |i| {
            const c = utf8[i];
            if (c >= 0b11000000) return error.InvalidUtf8;
        }
    }
    return dest_offset;
}

// test is from std.unicode.utf8ToUtf16Le
// https://github.com/ziglang/zig/blob/d03a147ea0a590ca711b3db07106effc559b0fc6/lib/std/unicode.zig#L1243-L1271
//
// Copyright (c) Zig contributors
// https://github.com/ziglang/zig/blob/d03a147ea0a590ca711b3db07106effc559b0fc6/LICENSE
test bad_utf8_to_utf16 {
    var utf16le: [128]u16 = undefined;
    {
        const length = try bad_utf8_to_utf16("𐐷", utf16le[0..]);
        try std.testing.expectEqualSlices(u8, "\x01\xd8\x37\xdc", std.mem.sliceAsBytes(utf16le[0..length]));
    }
    {
        const length = try bad_utf8_to_utf16("\u{10FFFF}", utf16le[0..]);
        try std.testing.expectEqualSlices(u8, "\xff\xdb\xff\xdf", std.mem.sliceAsBytes(utf16le[0..length]));
    }
    {
        const result = bad_utf8_to_utf16("\xf4\x90\x80\x80", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const length = try bad_utf8_to_utf16("This string has been designed to test the vectorized implementat" ++
            "ion by beginning with one hundred twenty-seven ASCII characters¡", utf16le[0..]);
        try std.testing.expectEqualSlices(u8, &.{
            'T', 0, 'h', 0, 'i', 0, 's', 0, ' ', 0, 's', 0, 't', 0, 'r', 0, 'i', 0, 'n', 0, 'g', 0, ' ', 0, 'h', 0, 'a', 0, 's', 0, ' ',  0,
            'b', 0, 'e', 0, 'e', 0, 'n', 0, ' ', 0, 'd', 0, 'e', 0, 's', 0, 'i', 0, 'g', 0, 'n', 0, 'e', 0, 'd', 0, ' ', 0, 't', 0, 'o',  0,
            ' ', 0, 't', 0, 'e', 0, 's', 0, 't', 0, ' ', 0, 't', 0, 'h', 0, 'e', 0, ' ', 0, 'v', 0, 'e', 0, 'c', 0, 't', 0, 'o', 0, 'r',  0,
            'i', 0, 'z', 0, 'e', 0, 'd', 0, ' ', 0, 'i', 0, 'm', 0, 'p', 0, 'l', 0, 'e', 0, 'm', 0, 'e', 0, 'n', 0, 't', 0, 'a', 0, 't',  0,
            'i', 0, 'o', 0, 'n', 0, ' ', 0, 'b', 0, 'y', 0, ' ', 0, 'b', 0, 'e', 0, 'g', 0, 'i', 0, 'n', 0, 'n', 0, 'i', 0, 'n', 0, 'g',  0,
            ' ', 0, 'w', 0, 'i', 0, 't', 0, 'h', 0, ' ', 0, 'o', 0, 'n', 0, 'e', 0, ' ', 0, 'h', 0, 'u', 0, 'n', 0, 'd', 0, 'r', 0, 'e',  0,
            'd', 0, ' ', 0, 't', 0, 'w', 0, 'e', 0, 'n', 0, 't', 0, 'y', 0, '-', 0, 's', 0, 'e', 0, 'v', 0, 'e', 0, 'n', 0, ' ', 0, 'A',  0,
            'S', 0, 'C', 0, 'I', 0, 'I', 0, ' ', 0, 'c', 0, 'h', 0, 'a', 0, 'r', 0, 'a', 0, 'c', 0, 't', 0, 'e', 0, 'r', 0, 's', 0, '¡', 0,
        }, std.mem.sliceAsBytes(utf16le[0..length]));
    }

    // based on summary from https://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
    {
        const result = bad_utf8_to_utf16("\xc0\x00", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xc0\xc0", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xe0\x80\xcf", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xf0\x80\xcf\xcf", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xed\xa0\xcf", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xf4\x90\xcf\xcf", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
}

pub fn find_darktide_steam(allocator: std.mem.Allocator) !OsStr {
    if (builtin.os.tag == .windows) {
        const vdf_path = "\n\t\t\"path\"";
        const darktide_id = "\n\t\t\t\"1361210";
        const end_apps = "\n\t\t}";
        const darktide_suffix = os.into_os_str(
            \\steamapps\common\Warhammer 40,000 DARKTIDE\bundle
        );

        var path_buffer = try allocator.alloc(u16, 2048);
        errdefer if (!root.leak_resources) allocator.free(path_buffer);

        path_buffer[0] = '\\';
        path_buffer[1] = '?';
        path_buffer[2] = '?';
        path_buffer[3] = '\\';
        var offset: u32 = 4;
        offset += try steam_dir_reg(path_buffer[offset..path_buffer.len - 1]);
        path_buffer[offset] = '\\';
        offset += 1;
        mem.memcpy(path_buffer[offset..offset + library_vdf.len], library_vdf);
        offset += library_vdf.len;
        path_buffer[offset] = 0;

        const data = try read_file(allocator, path_buffer[0..offset :0]);
        defer if (!root.leak_resources) allocator.free(data);

        var index: usize = 0;
        var buffer: [2048:0]u8 = [_:0]u8{0} ** 2048;
        return path: while (index < data.len) {
            index = mem.index_of_pos(data, index, vdf_path)
                orelse return error.NotFoundDarktide;
            index += vdf_path.len;
            while (data[index] != '"') index += 1;
            const size = parse_string(data[index..], &buffer) orelse return error.NotFoundDarktide;
            const path_utf8 = buffer[0..size];

            const end = mem.index_of_pos(data, index, end_apps)
                orelse return error.NotFoundDarktide;

            if (mem.index_of_pos(data[index..end], 0, darktide_id)) |_| {
                var utf16_size: usize = try bad_utf8_to_utf16(path_utf8, path_buffer[4..]);
                utf16_size += 4;
                path_buffer[utf16_size] = '\\';
                utf16_size += 1;
                mem.memcpy(path_buffer[utf16_size..utf16_size + darktide_suffix.len], darktide_suffix);
                utf16_size += darktide_suffix.len;
                path_buffer[utf16_size] = 0;
                break :path path_buffer[0..utf16_size :0];
            }
        } else return error.NotFoundDarktide;
    } else {
        @compileError("find_darktide_steam is currently only supported on windows");
    }
}
